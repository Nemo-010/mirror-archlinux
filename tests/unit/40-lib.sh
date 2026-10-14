#!/usr/bin/env bash
#
# The decisions the sync makes, each on fixed inputs: which target files are
# valid, which database fields are refused, which database is behind another,
# when a package tag may be written, when a target is stale, which snapshot is
# newer, and how a shard accounts for every file.
set -euo pipefail
# shellcheck source=../lib/harness.sh
. "$REPO_ROOT/tests/lib/harness.sh"

work="$(work_dir)"
trap 'rm -rf "$work"' EXIT

LIB="$REPO_ROOT/scripts/lib.sh"

# in_lib CMD... -> runs CMD in a shell that sourced lib.sh; prints its output,
# returns its status. die() exits that shell, not this one.
in_lib() {
  # Called as the scripts call a predicate, in a condition: a refusal is an
  # answer, and lib.sh's ERR trap then stays quiet, as it does in the scripts.
  bash -c '. "$1"; shift; "$@" || exit $?' _ "$LIB" "$@"
}

#---------------------------------------------------------------------------#
# Target files
#---------------------------------------------------------------------------#
mkdir -p "$work/targets"
good="$work/targets/x86_64-core.conf"
cat > "$good" << 'EOF'
# a comment
arch = x86_64
repo = core
db_server = https://example.invalid/$repo/os/$arch
server = https://mirror.example.invalid/$repo/os/$arch
keyring = archlinux-keyring
EOF
rc=0
in_lib target_check "$good" > /dev/null 2>&1 || rc=$?
check "a good target file is accepted" 0 "$rc" "bash -c '. scripts/lib.sh; target_check FILE'"
check "server lines expand \$repo and \$arch" "https://mirror.example.invalid/core/os/x86_64" \
  "$(in_lib target_all "$good" server)" "bash -c '. scripts/lib.sh; target_all FILE server'"
check "package sources are the db_servers, then the servers" \
  "$(printf '%s\n' https://example.invalid/core/os/x86_64 https://mirror.example.invalid/core/os/x86_64)" \
  "$(in_lib target_sources "$good")" "bash -c '. scripts/lib.sh; target_sources FILE'"

refused() {
  local label="$1" file="$2" rc=0
  in_lib target_check "$file" > /dev/null 2>&1 || rc=$?
  if [ "$rc" -ne 0 ]; then
    ok "refused: $label"
  else
    fail "refused: $label" "target_check accepted it" "reproduce: bash -c '. scripts/lib.sh; target_check $file'"
  fi
}
sed '/^db_server/d' "$good" > "$work/targets/x86_64-core.conf.tmp"
mkdir -p "$work/t1" && mv "$work/targets/x86_64-core.conf.tmp" "$work/t1/x86_64-core.conf"
refused "a target with no db_server" "$work/t1/x86_64-core.conf"
mkdir -p "$work/t2" && { cat "$good"; echo 'mirrors = https://x.invalid'; } > "$work/t2/x86_64-core.conf"
refused "an unknown key" "$work/t2/x86_64-core.conf"
mkdir -p "$work/t3" && { cat "$good"; echo 'repo = extra'; } > "$work/t3/x86_64-core.conf"
refused "a key given twice" "$work/t3/x86_64-core.conf"
mkdir -p "$work/t4" && cp "$good" "$work/t4/x86_64-extra.conf"
refused "a file not named arch-repo.conf" "$work/t4/x86_64-extra.conf"
mkdir -p "$work/t5" && { cat "$good"; echo 'db_signed = maybe'; } > "$work/t5/x86_64-core.conf"
refused "db_signed that is not yes or no" "$work/t5/x86_64-core.conf"
mkdir -p "$work/t6" && { cat "$good"; echo 'not a key value line'; } > "$work/t6/x86_64-core.conf"
refused "a line that is not key = value" "$work/t6/x86_64-core.conf"

#---------------------------------------------------------------------------#
# Database fields
#---------------------------------------------------------------------------#
SHA=41cf0bb5df14e18f7fb868a97da3feb7c4127fba99bb332ad54b14322faac1b1
rec() {
  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "${5:-$SHA}" "${6:-84690}" "${7:-1790000000}" "${8:-}"
}
valid() {
  local label="$1" want="$2" rc=0
  shift 2
  rec "$@" > "$work/rec.tsv"
  in_lib db_validate "$work/rec.tsv" > /dev/null 2>&1 || rc=$?
  if [ "$want" = accept ]; then
    check "db field check accepts $label" 0 "$rc" "bash -c '. scripts/lib.sh; db_validate RECORDS'"
  else
    check "db field check refuses $label" 1 "$rc" "bash -c '. scripts/lib.sh; db_validate RECORDS'"
  fi
}
valid "an epoch and a +" accept 'zlib-1:1.3.2+r2-3-x86_64.pkg.tar.zst' zlib '1:1.3.2+r2-3' x86_64
valid "a ~ in a version, which makepkg allows" accept 'foo-1.0~rc1-1-any.pkg.tar.zst' foo '1.0~rc1-1' any
valid "an uncompressed package" accept 'foo-1-1-any.pkg.tar' foo '1-1' any
valid "a path traversal" refuse '../../scripts/stage.pkg.tar.zst' foo '1-1' any
valid "a leading -" refuse '-rf-1-1-any.pkg.tar.zst' -rf '1-1' any
valid "a space" refuse 'foo bar-1-1-any.pkg.tar.zst' 'foo bar' '1-1' any
valid "a / inside" refuse 'foo/bar-1-1-any.pkg.tar.zst' foo '1-1' any
# Only the / is wrong here: the name, version and arch prefix all match, so
# nothing but the character check stands between this and a path.
valid "a / alone, after a valid prefix" refuse 'foo-1-1-any.pkg.tar/../../x.pkg.tar.zst' foo '1-1' any
valid "a sha256 that is not one" refuse 'foo-1-1-any.pkg.tar.zst' foo '1-1' any nothex
valid "a size that is not a number" refuse 'foo-1-1-any.pkg.tar.zst' foo '1-1' any "$SHA" 12k
valid "a filename that is not name-version-arch" refuse 'bar-1-1-any.pkg.tar.zst' foo '1-1' any
valid "a signature that is not base64" refuse 'foo-1-1-any.pkg.tar.zst' foo '1-1' any "$SHA" 1 1 'not base64!'

{ rec 'foo-1-1-any.pkg.tar.zst' foo '1-1' any; rec 'foo-1-1-any.pkg.tar.zst' foo '1-1' any; } > "$work/rec.tsv"
rc=0
in_lib db_validate "$work/rec.tsv" > /dev/null 2>&1 || rc=$?
check "db field check refuses a filename listed twice" 1 "$rc" "bash -c '. scripts/lib.sh; db_validate RECORDS'"

#---------------------------------------------------------------------------#
# Behind: compared per package by build date. Fixtures are Arch's archived
# core.db of four days, reduced to name and build date: 10-02 and 10-03 share
# their newest build date and differ in bytes, and so do 10-10 and 10-11. The
# newest build date alone would pick either; the per-package rule does not.
#---------------------------------------------------------------------------#
fx="$REPO_ROOT/tests/fixtures/builddates"
as_records() {
  awk -F '\t' '{ printf "f\t%s\tv\ta\ts\t1\t%s\t\n", $1, $2 }' "$1"
}
for pair in "02 03" "10 11"; do
  read -r a b <<< "$pair"
  as_records "$fx/core-2026-10-$a.builddates" > "$work/a.tsv"
  as_records "$fx/core-2026-10-$b.builddates" > "$work/b.tsv"
  read -r newer older <<< "$(in_lib behind "$work/a.tsv" "$work/b.tsv")"
  if [ "$older" -eq 0 ] && [ "$newer" -gt 0 ]; then
    ok "core of 10-$b is not behind 10-$a ($newer newer, $older older)"
  else
    fail "core of 10-$b is not behind 10-$a" "newer $newer, older $older" "reproduce: bash -c '. scripts/lib.sh; behind A B'"
  fi
  read -r newer older <<< "$(in_lib behind "$work/b.tsv" "$work/a.tsv")"
  if [ "$older" -gt 0 ]; then
    ok "core of 10-$a is behind 10-$b ($older package(s) older)"
  else
    fail "core of 10-$a is behind 10-$b" "newer $newer, older $older" "reproduce: bash -c '. scripts/lib.sh; behind B A'"
  fi
done
cp "$work/a.tsv" "$work/a-again.tsv"
check "a database is not behind itself" "0 0" "$(in_lib behind "$work/a.tsv" "$work/a-again.tsv")" "bash -c '. scripts/lib.sh; behind A COPY-OF-A'"

#---------------------------------------------------------------------------#
# The write-once rule
#---------------------------------------------------------------------------#
F='zlib-1:1.3.2-3-x86_64.pkg.tar.zst'
SIG=0000000000000000000000000000000000000000000000000000000000000001
OTHER=1111111111111111111111111111111111111111111111111111111111111111
manifest() {
  # manifest PKG_DIGEST PKG_SIZE PKG_TYPE [SIG_DIGEST SIG_TYPE]
  local layers
  layers="$(jq -cn --arg d "sha256:$1" --argjson s "$2" --arg t "$3" --arg f "$F" \
    '[{mediaType: $t, digest: $d, size: $s, annotations: {"org.opencontainers.image.title": $f}}]')"
  if [ -n "${4:-}" ]; then
    layers="$(printf '%s' "$layers" | jq -c --arg d "sha256:$4" --arg t "$5" --arg f "$F.sig" \
      '. + [{mediaType: $t, digest: $d, size: 119, annotations: {"org.opencontainers.image.title": $f}}]')"
  fi
  jq -cn --argjson l "$layers" '{schemaVersion: 2, mediaType: "application/vnd.oci.image.manifest.v1+json", layers: $l}' > "$work/m.json"
}
PKG_T=application/vnd.pkgforge.archlinux.pkg.v1
SIG_T=application/pgp-signature
decide() {
  in_lib decide_push "$work/m.json" "$F" "$SHA" 84690 "$1"
}
manifest "$SHA" 84690 "$PKG_T" "$SIG" "$SIG_T"
check "write-once: the tag holds this file and its signature" present "$(decide "$SIG")" "lib.sh decide_push"
manifest "$OTHER" 84690 "$PKG_T" "$SIG" "$SIG_T"
check "write-once: other bytes under this name are never overwritten" replaced "$(decide "$SIG")" "lib.sh decide_push"
jq -cn '{schemaVersion: 2, layers: [{mediaType: "x", digest: "sha256:'"$SHA"'", size: 1, annotations: {"org.opencontainers.image.title": "another-file"}}]}' > "$work/m.json"
check "write-once: a tag holding another file is never overwritten" replaced "$(decide "$SIG")" "lib.sh decide_push"
echo '{"schemaVersion":2}' > "$work/m.json"
check "write-once: a tag holding no layers at all is never overwritten" replaced "$(decide "$SIG")" "lib.sh decide_push"
manifest "$SHA" 84690 "$PKG_T"
check "write-once: the right package with its signature missing is pushed again" repush "$(decide "$SIG")" "lib.sh decide_push"
manifest "$SHA" 84690 "$PKG_T" "$OTHER" "$SIG_T"
check "write-once: the right package with another signature is pushed again" repush "$(decide "$SIG")" "lib.sh decide_push"
manifest "$SHA" 1 "$PKG_T" "$SIG" "$SIG_T"
check "write-once: the right digest with the wrong size is pushed again" repush "$(decide "$SIG")" "lib.sh decide_push"
manifest "$SHA" 84690 application/octet-stream "$SIG" "$SIG_T"
check "write-once: the right digest with the wrong media type is pushed again" repush "$(decide "$SIG")" "lib.sh decide_push"
manifest "$SHA" 84690 "$PKG_T"
check "write-once: no %PGPSIG% and no signature layer: fetch the .sig" needsig "$(decide '')" "lib.sh decide_push"
manifest "$SHA" 84690 "$PKG_T" "$OTHER" "$SIG_T"
check "write-once: no %PGPSIG%, and the signature layer present is kept" present "$(decide '')" "lib.sh decide_push"

#---------------------------------------------------------------------------#
# Staleness, with a fixed clock
#---------------------------------------------------------------------------#
A=aaaa B=bbbb
check "stale: latest serves upstream's database" current \
  "$(in_lib stale_verdict "$A" "$A" 2026-01-01T00:00:00Z 2026-10-13 3)" "lib.sh stale_verdict"
check "stale: different, fetched within the tolerance" fresh \
  "$(in_lib stale_verdict "$A" "$B" 2026-10-11T23:00:00Z 2026-10-13 3)" "lib.sh stale_verdict"
check "stale: different, fetched longer ago than the tolerance" stale \
  "$(in_lib stale_verdict "$A" "$B" 2026-10-09T23:00:00Z 2026-10-13 3)" "lib.sh stale_verdict"
check "stale: nothing promoted at all" stale \
  "$(in_lib stale_verdict "" "$B" "" 2026-10-13 3)" "lib.sh stale_verdict"
check "stale: upstream unreadable says nothing" unknown \
  "$(in_lib stale_verdict "$A" "" 2026-10-01T00:00:00Z 2026-10-13 3)" "lib.sh stale_verdict"

#---------------------------------------------------------------------------#
# latest never moves backwards: the staged snapshot's fetched time against
# the live one's
#---------------------------------------------------------------------------#
order() {
  local rc=0
  in_lib fetched_not_older "$1" "$2" || rc=$?
  printf '%s\n' "$rc"
}
check "a later snapshot may be promoted" 0 "$(order 2026-10-13T09:17:00Z 2026-10-13T06:17:00Z)" "lib.sh fetched_not_older"
check "the same snapshot may be promoted again" 0 "$(order 2026-10-13T09:17:00Z 2026-10-13T09:17:00Z)" "lib.sh fetched_not_older"
check "an earlier snapshot is refused" 1 "$(order 2026-10-12T23:59:59Z 2026-10-13T00:00:00Z)" "lib.sh fetched_not_older"

#---------------------------------------------------------------------------#
# A shard accounts for every work line, and a line with no result failed.
#---------------------------------------------------------------------------#
printf 't\ta.pkg.tar.zst\n' > "$work/shard.tsv"
printf 't\tb.pkg.tar.zst\n' >> "$work/shard.tsv"
printf 't\tc.pkg.tar.zst\n' >> "$work/shard.tsv"
mkdir -p "$work/results"
printf 't\ta.pkg.tar.zst\tpushed\t1\tok\n' > "$work/results/1.tsv"
printf 't\tc.pkg.tar.zst\tpresent\t0\tok\n' > "$work/results/3.tsv"
bad="$(in_lib reconcile_results "$work/shard.tsv" "$work/results" "$work/all.tsv")"
check "an item that left no result is counted as failed" 1 "$bad" "lib.sh reconcile_results"
check "every work line has exactly one result line" 3 "$(awk 'END { print NR }' "$work/all.tsv")" "lib.sh reconcile_results"
check "the missing one is named, with its target" "t b.pkg.tar.zst failed" "$(awk -F '\t' '$3 == "failed" { print $1 " " $2 " " $3 }' "$work/all.tsv")" "lib.sh reconcile_results"

summary
