#!/usr/bin/env bash
#
# The whole mirror, end to end, against a registry and an upstream of its own.
#
# A local registry (registry:3) stands in for GHCR and a local web server for
# the upstream mirror. A signed repository is built with filenames that stress
# the tag mapping. Then the real scripts run as the workflow runs them: plan,
# mirror-shard, stage, verify-batch, promote. pacman in an Arch container then
# installs from the mirror through the wrapper, with and without DownloadUser,
# and the cases that must be refused are driven on purpose: a database older
# than the promoted one, a file that changed under its own name, and a tag
# that already holds other bytes.
#
# Needs docker or podman (CONTAINER_RUNTIME), curl, jq, tar, sha256sum, and
# network to pull the pinned images and oras.
set -euo pipefail
# shellcheck source=../lib/harness.sh
. "$REPO_ROOT/tests/lib/harness.sh"

# tag: base
ARCH_IMAGE=docker.io/library/archlinux:base@sha256:3c64b538588416593f69a1aebd2f2ec0f2541b29159f32556fa7def2167147a0
# tag: 3
REGISTRY_IMAGE=docker.io/library/registry:3@sha256:ddf754342cfc8acc51a56d5d0ab6af06826461864460636d8bd5c546dab2a7b8
# tag: 1.37
HTTPD_IMAGE=docker.io/library/busybox:1.37@sha256:bdf57e528e45e4433820e045b29b4597825a1c9e38353532d90a01445013f82e
REG_PORT="${IT_REGISTRY_PORT:-5055}"
UP_PORT="${IT_UPSTREAM_PORT:-5056}"

runtime_detect
work="$(work_dir)"
reg_name="mirror-it-registry-$$"
up_name="mirror-it-upstream-$$"
cleanup() {
  "$RUNTIME" rm -f "$reg_name" "$up_name" > /dev/null 2>&1 || :
  if [ "${IT_KEEP:-0}" = 1 ]; then
    echo "# kept $work" >&2
  else
    rm -rf "$work"
  fi
}
trap cleanup EXIT

# Containers that write into the work directory do so as the calling user,
# so the directory can be removed afterwards without root.
as_me=(--user "$(id -u):$(id -g)")
case "$(basename "$RUNTIME")" in
  *podman*) as_me=(--userns keep-id) ;;
esac

mkdir -p "$work/upstream" "$work/targets" "$work/out"

#---------------------------------------------------------------------------#
# The registry and the upstream
#---------------------------------------------------------------------------#
"$RUNTIME" run -d --rm --name "$reg_name" -p "127.0.0.1:$REG_PORT:5000" "$REGISTRY_IMAGE" > /dev/null
"$RUNTIME" run -d --rm --name "$up_name" -p "127.0.0.1:$UP_PORT:8000" -v "$work/upstream:/srv:ro" \
  "$HTTPD_IMAGE" httpd -f -p 8000 -h /srv > /dev/null
ready=0
for _ in $(seq 1 30); do
  if curl -q -fsS --connect-timeout 2 --max-time 5 "http://127.0.0.1:$REG_PORT/v2/" > /dev/null &&
    curl -q -sS --connect-timeout 2 --max-time 5 -o /dev/null "http://127.0.0.1:$UP_PORT/"; then
    ready=1
    break
  fi
  sleep 1
done
if [ "$ready" -ne 1 ]; then
  fail "the local registry and upstream answer" "after 30 s" "reproduce: $RUNTIME logs $reg_name; $RUNTIME logs $up_name"
  summary
  exit 1
fi

build() {
  "$RUNTIME" run --rm "${as_me[@]}" -e HOME=/tmp -v "$work/upstream:/out" \
    -v "$REPO_ROOT/tests/fixtures/build-repo:/build-repo.sh:ro" \
    "$ARCH_IMAGE" bash /build-repo.sh "$1" "${2:-test}" > "$work/build-$1.log" 2>&1
}

cat > "$work/targets/x86_64-test.conf" << EOF
arch = x86_64
repo = test
db_server = http://127.0.0.1:$UP_PORT/\$arch/\$repo
server = http://127.0.0.1:$UP_PORT/\$arch/\$repo
# tag: base
verify_image = $ARCH_IMAGE
verify_platform = linux/amd64
EOF

export TARGETS_DIR="$work/targets"
export MIRROR_REGISTRY="127.0.0.1:$REG_PORT"
export MIRROR_REGISTRY_SCHEME=http
export MIRROR_REGISTRY_AUTH=none
export MIRROR_NAMESPACE=it/mirror
export UPSTREAM_PROTO='=http,https'
export VERIFY_NETWORK=host
export VERIFY_TRUST_KEY="$work/upstream/test.asc"
export CONTAINER_RUNTIME="$RUNTIME"
export SHARD_FILES=2
export PARALLEL=2
REPO="it/mirror/x86_64/test"
BASE="http://127.0.0.1:$REG_PORT/v2/$REPO"

# sync N: one run, every step, as the workflow does it; state in $work/out/N
sync() {
  local o="$work/out/$1" s b rc=0
  mkdir -p "$o"
  if ! "$REPO_ROOT/scripts/plan" "$o/plan" > "$o/plan.log" 2>&1; then
    diag "sync $1: plan failed"
    logs_of "$1"
    return 0
  fi
  for s in "$o"/plan/shards/*.tsv; do
    [ -e "$s" ] || continue
    rc=0
    SHARD_INDEX="$(basename "$s" .tsv)" "$REPO_ROOT/scripts/mirror-shard" "$s" "$o/results/$(basename "$s" .tsv)" \
      > "$o/mirror-$(basename "$s" .tsv).log" 2>&1 || rc=$?
  done
  if ! "$REPO_ROOT/scripts/stage" "$o/plan" "$o/results" "$o/stage" > "$o/stage.log" 2>&1; then
    diag "sync $1: stage failed"
    logs_of "$1"
    return 0
  fi
  for b in "$o"/stage/x86_64-test/batches/*.txt; do
    [ -e "$b" ] || continue
    "$REPO_ROOT/scripts/verify-batch" "$o/stage" x86_64-test "$(basename "$b" .txt)" "$o/verify" \
      > "$o/verify-$(basename "$b" .txt).log" 2>&1 || rc=$?
  done
  "$REPO_ROOT/scripts/promote" "$o/stage" "$o/verify" x86_64-test > "$o/promote.log" 2>&1 || rc=$?
  return 0
}

state_of() {
  if [ -f "$work/out/$1/$2/x86_64-test/state" ]; then
    cat "$work/out/$1/$2/x86_64-test/state"
  else
    echo "no state"
  fi
}

manifest() {
  curl -q -fsS --connect-timeout 5 --max-time 20 -H 'Accept: application/vnd.oci.image.manifest.v1+json' "$BASE/manifests/$1"
}

# digest_of TAG -> the digest the tag names, or nothing when it names none
digest_of() {
  curl -q -sS --connect-timeout 5 --max-time 20 -o /dev/null -D - \
    -H 'Accept: application/vnd.oci.image.manifest.v1+json' "$BASE/manifests/$1" |
    tr -d '\r' | awk '$1 ~ /^HTTP/ { ok = ($2 == 200) } ok && tolower($1) == "docker-content-digest:" { print $2 }'
}

# pgpsig_count: how many %PGPSIG% the upstream database carries
pgpsig_count() {
  tar -xOzf "$work/upstream/x86_64/test/test.db" | awk '$0 == "%PGPSIG%" { n++ } END { print n + 0 }'
}

# pgpsig_of FILE: the %PGPSIG% the upstream database carries for FILE
pgpsig_of() {
  tar -xOzf "$work/upstream/x86_64/test/test.db" |
    awk -v f="$1" 'k == "F" { cur = $0 } k == "P" && cur == f { print } { k = ($0 == "%FILENAME%") ? "F" : ($0 == "%PGPSIG%") ? "P" : "" }'
}

logs_of() {
  local f
  for f in "$work/out/$1"/*.log; do
    diag "--- $(basename "$f")"
    while IFS= read -r l; do diag "$l"; done < <(tail -n 15 "$f")
  done
}

#---------------------------------------------------------------------------#
# 1. First sync: everything is new
#---------------------------------------------------------------------------#
build one
check "the fixture's database carries a %PGPSIG% for each of its 3 packages, as core's does" 3 "$(pgpsig_count)" \
  "tar -xOzf upstream/x86_64/test/test.db | grep -c PGPSIG; tests/fixtures/build-repo must run repo-add --include-sigs"
sync 1
check "first sync: the plan finds work" pending "$(state_of 1 plan)" "tests/integration/10-pipeline.sh, then read out/1/plan.log"
check "first sync: the database is staged" staged "$(state_of 1 stage)" "read out/1/stage.log"
if [ -s "$work/out/1/stage/x86_64-test/promoted.tsv" ]; then
  ok "first sync: the database is promoted"
else
  fail "first sync: the database is promoted" "no promoted.tsv"
  logs_of 1
fi
check "verify compares each .sig pacman stored with its %PGPSIG%" 3 \
  "$(sed -n 's/^\([0-9][0-9]*\) signature(s) compared$/\1/p' "$work/out/1/verify/verify-x86_64-test-0.log")" \
  "read out/1/verify/verify-x86_64-test-0.log"

for f in 'alpha-1:1.0+r2-1-any.pkg.tar.zst' 'beta_pc-2.0-1-x86_64.pkg.tar.zst' 'gamma-3.0-1-any.pkg.tar.zst'; do
  tag="$("$REPO_ROOT/client/pacman-oci" --tag "$f")"
  m="$(manifest "$tag")" || m=""
  titles="$(printf '%s' "$m" | jq -r '[.layers[]?.annotations["org.opencontainers.image.title"]] | join(" ")')"
  check "$f is under $tag with itself and its signature" "$f $f.sig" "$titles" "curl $BASE/manifests/$tag"
  want="$(sha256sum "$work/upstream/x86_64/test/$f" | cut -d ' ' -f 1)"
  got="$(printf '%s' "$m" | jq -r --arg t "$f" '.layers[] | select(.annotations["org.opencontainers.image.title"] == $t) | .digest')"
  check "$f layer is the upstream bytes" "sha256:$want" "$got" "curl $BASE/manifests/$tag"
  sig_want="$(pgpsig_of "$f" | base64 -d | sha256sum | cut -d ' ' -f 1)"
  sig_got="$(printf '%s' "$m" | jq -r --arg t "$f.sig" '.layers[] | select(.annotations["org.opencontainers.image.title"] == $t) | .digest')"
  check "$f signature layer is its %PGPSIG%, decoded" "sha256:$sig_want" "$sig_got" "curl $BASE/manifests/$tag"
done

latest1="$(digest_of latest)"
day="$(sed -n 's/^FETCHED=\([0-9]\{4\}\)-\([0-9]\{2\}\)-\([0-9]\{2\}\)T.*/\1.\2.\3/p' "$work/out/1/plan/x86_64-test/meta.env")"
check "latest and the dated tag name the same snapshot" "$latest1" "$(digest_of "$day")" "curl -I $BASE/manifests/$day"
db_hex="$(sha256sum "$work/upstream/x86_64/test/test.db" | cut -d ' ' -f 1)"
check "the snapshot is also tagged by its database's content" "$latest1" "$(digest_of "db-$db_hex")" "curl -I $BASE/manifests/db-$db_hex"

#---------------------------------------------------------------------------#
# 2. Consumers: pacman through the wrapper, nothing else
#---------------------------------------------------------------------------#
consumer() {
  local label="$1" server="$2" keep_download_user="$3" extra="${4:-}"
  cat > "$work/consumer.sh" << 'EOS'
set -euo pipefail
server="$1" keep="$2" extra="$3"
install -m 0755 /in/pacman-oci /usr/local/bin/pacman-oci
awk '
  /^\[/ { inopt = ($0 == "[options]") }
  inopt && /^[[:space:]]*XferCommand/ { next }
  inopt { print }
  /^\[options\]/ && !d { print "XferCommand = /usr/local/bin/pacman-oci %o %u"; d = 1 }
' /etc/pacman.conf > /tmp/pacman.conf
if [ "$keep" != yes ]; then
  sed -i '/^[[:space:]]*DownloadUser/d' /tmp/pacman.conf
fi
printf '\n[test]\nServer = %s\n' "$server" >> /tmp/pacman.conf
if [ -n "$extra" ]; then
  printf 'Server = %s\n' "$extra" >> /tmp/pacman.conf
fi
pacman-key --init > /dev/null 2>&1
pacman-key --add /in/test.asc > /dev/null 2>&1
pacman-key --lsign-key "$(gpg --with-colons --show-keys /in/test.asc | awk -F : '$1 == "fpr" { print $10; exit }')" > /dev/null 2>&1
pac() { pacman --config /tmp/pacman.conf --noconfirm "$@"; }
pac -Sy
pac -S alpha beta_pc gamma
cat /usr/share/mirror-test/alpha /usr/share/mirror-test/beta_pc /usr/share/mirror-test/gamma
pac -Fy
pacman --config /tmp/pacman.conf -Fl gamma
echo CONSUMER-OK
EOS
  local rc=0
  "$RUNTIME" run --rm --network host \
    -v "$REPO_ROOT/client/pacman-oci:/in/pacman-oci:ro" \
    -v "$work/upstream/test.asc:/in/test.asc:ro" \
    -v "$work/consumer.sh:/in/consumer.sh:ro" \
    "$ARCH_IMAGE" bash /in/consumer.sh "$server" "$keep_download_user" "$extra" > "$work/consumer-$label.log" 2>&1 || rc=$?
  if [ "$rc" -eq 0 ] && grep -q CONSUMER-OK "$work/consumer-$label.log"; then
    ok "consumer, $label: pacman -Sy, -S and -Fy through the wrapper"
  else
    fail "consumer, $label: pacman -Sy, -S and -Fy through the wrapper" "exit $rc"
    while IFS= read -r l; do diag "$l"; done < <(tail -n 25 "$work/consumer-$label.log")
  fi
}

consumer "stock DownloadUser" "oci+http://127.0.0.1:$REG_PORT/$REPO" yes
consumer "no DownloadUser" "oci+http://127.0.0.1:$REG_PORT/$REPO" no
consumer "a snapshot pinned by digest" "oci+http://127.0.0.1:$REG_PORT/$REPO@$latest1" yes
consumer "a dated snapshot" "oci+http://127.0.0.1:$REG_PORT/$REPO:$day" yes
consumer "the registry missing, upstream after it" "oci+http://127.0.0.1:$REG_PORT/it/nowhere/x86_64/test" yes \
  "http://127.0.0.1:$UP_PORT/x86_64/test"

#---------------------------------------------------------------------------#
# 3. Nothing changed upstream: nothing to do
#---------------------------------------------------------------------------#
sync 2
check "an unchanged upstream is current" current "$(state_of 2 plan)" "read out/2/plan.log"
check "an unchanged upstream leaves latest where it was" "$latest1" "$(digest_of latest)" "curl -I $BASE/manifests/latest"

#---------------------------------------------------------------------------#
# 4. One package updated: only it is mirrored, latest moves, the day's tag
#    keeps the first snapshot
#---------------------------------------------------------------------------#
build two
sync 3
check "an update is planned as one new file" 1 "$(awk 'END { print NR + 0 }' "$work/out/3/plan/x86_64-test/todo.tsv")" "read out/3/plan/x86_64-test/todo.tsv"
check "the update is promoted" staged "$(state_of 3 stage)" "read out/3/stage.log"
latest3="$(digest_of latest)"
if [ -n "$latest3" ] && [ "$latest3" != "$latest1" ]; then
  ok "latest moved to the new snapshot"
else
  fail "latest moved to the new snapshot" "latest is $latest3"
  logs_of 3
fi
check "the dated tag still names the day's first snapshot" "$latest1" "$(digest_of "$day")" "curl -I $BASE/manifests/$day"

# The first run's stage and verdicts, promoted again after a later run: what a
# "re-run failed jobs" days later would do. It must not move latest back.
rc=0
"$REPO_ROOT/scripts/promote" "$work/out/1/stage" "$work/out/1/verify" x86_64-test > "$work/out/promote-again.log" 2>&1 || rc=$?
if [ "$rc" -ne 0 ] && grep -q 'before the one latest names' "$work/out/promote-again.log"; then
  ok "promoting an older run's snapshot again is refused"
else
  fail "promoting an older run's snapshot again is refused" "exit $rc" "$(tail -n 3 "$work/out/promote-again.log")"
fi
check "latest stays on the newer snapshot" "$latest3" "$(digest_of latest)" "curl -I $BASE/manifests/latest"

#---------------------------------------------------------------------------#
# 5. Upstream goes back to an older database: refused, latest stays
#---------------------------------------------------------------------------#
build one
sync 4
check "an older upstream database is refused as behind" behind "$(state_of 4 plan)" "read out/4/plan.log"
check "latest does not move backwards" "$latest3" "$(digest_of latest)" "curl -I $BASE/manifests/latest"

#---------------------------------------------------------------------------#
# 6. A file changes under its own name: held, nothing overwritten
#---------------------------------------------------------------------------#
build replaced
beta_tag="$("$REPO_ROOT/client/pacman-oci" --tag 'beta_pc-2.0-1-x86_64.pkg.tar.zst')"
beta_before="$(digest_of "$beta_tag")"
sync 5
check "a file whose bytes changed under its own name holds the target" replaced "$(state_of 5 stage)" "read out/5/stage.log"
check "its tag is not overwritten" "$beta_before" "$(digest_of "$beta_tag")" "curl -I $BASE/manifests/$beta_tag"
check "latest stays" "$latest3" "$(digest_of latest)" "curl -I $BASE/manifests/latest"

#---------------------------------------------------------------------------#
# 7. A new file whose tag already holds other bytes: held, never pushed over
#---------------------------------------------------------------------------#
build three
delta='delta-1-1-any.pkg.tar.zst'
delta_tag="$("$REPO_ROOT/client/pacman-oci" --tag "$delta")"
mkdir -p "$work/bogus"
printf 'not the package\n' > "$work/bogus/$delta"
ORAS_BIN="$("$REPO_ROOT/scripts/install-oras" "$work/bin")"
(cd "$work/bogus" && timeout 120 "$ORAS_BIN" push --plain-http "$MIRROR_REGISTRY/$REPO:$delta_tag" \
  "./$delta:application/vnd.pkgforge.archlinux.pkg.v1" > /dev/null)
bogus="$(digest_of "$delta_tag")"
sync 6
check "a new file whose tag already holds other bytes holds the target" replaced "$(state_of 6 stage)" "read out/6/stage.log"
check "the conflicting tag is not overwritten" "$bogus" "$(digest_of "$delta_tag")" "curl -I $BASE/manifests/$delta_tag"
check "latest stays through a conflict" "$latest3" "$(digest_of latest)" "curl -I $BASE/manifests/latest"

#---------------------------------------------------------------------------#
# 8. Two db_servers that disagree: each is ahead of the other on one package
#    and behind on another, and neither is behind what is promoted. Nothing
#    says which is newer, so the target is held, not guessed.
#---------------------------------------------------------------------------#
build ahead-alpha test
build ahead-gamma test-b
mkdir -p "$work/targets-two"
{
  grep -v '^db_server' "$work/targets/x86_64-test.conf"
  # shellcheck disable=SC2016 # $arch and $repo are the target file's, not the shell's
  printf 'db_server = http://127.0.0.1:%s/$arch/$repo\ndb_server = http://127.0.0.1:%s/$arch/test-b\n' "$UP_PORT" "$UP_PORT"
} > "$work/targets-two/x86_64-test.conf"
rc=0
TARGETS_DIR="$work/targets-two" "$REPO_ROOT/scripts/plan" "$work/out/held" > "$work/out/held.log" 2>&1 || rc=$?
check "db_servers that disagree hold the target" held \
  "$(cat "$work/out/held/x86_64-test/state" 2> /dev/null || echo "no state, plan exit $rc")" "read out/held.log"

#---------------------------------------------------------------------------#
# 9. A package signed by a key nobody trusts: mirrored, staged, refused by
#    pacman in verify, and never promoted.
#---------------------------------------------------------------------------#
build untrusted
sync 7
check "a package with an untrusted signature is staged" staged "$(state_of 7 stage)" "read out/7/stage.log"
verdict="$(cut -f 3,4 "$work/out/7/verify/verify-x86_64-test-0.tsv" 2> /dev/null || echo 'no verdict')"
case "$verdict" in
  failed*epsilon*) ok "verify fails it, and names the package" ;;
  *) fail "verify fails it, and names the package" "verdict: $verdict" "read out/7/verify/verify-x86_64-test-0.log" ;;
esac
check "an untrusted package is never promoted" "$latest3" "$(digest_of latest)" "curl -I $BASE/manifests/latest"

#---------------------------------------------------------------------------#
# 9b. A database with no %PGPSIG%, as most of ArchPOWER's: the signature of a
#     new package comes from upstream's detached .sig, byte for byte, and
#     pacman verifies against it through the wrapper.
#---------------------------------------------------------------------------#
build nopgpsig
check "the fixture's database carries no %PGPSIG%" 0 "$(pgpsig_count)" "tar -xOzf upstream/x86_64/test/test.db | grep -c PGPSIG"
sync 8
check "a database without %PGPSIG% stages" staged "$(state_of 8 stage)" "read out/8/stage.log"
zeta='zeta-1-1-any.pkg.tar.zst'
zeta_sig="$(manifest "$("$REPO_ROOT/client/pacman-oci" --tag "$zeta")" | jq -r --arg t "$zeta.sig" '.layers[] | select(.annotations["org.opencontainers.image.title"] == $t) | .digest')"
check "its signature layer is upstream's detached .sig" "sha256:$(sha256sum "$work/upstream/x86_64/test/$zeta.sig" | cut -d ' ' -f 1)"   "$zeta_sig" "curl $BASE/manifests/<zeta tag>"
check "pacman verifies it against that .sig" passed "$(cut -f 3 "$work/out/8/verify/verify-x86_64-test-0.tsv" 2> /dev/null || echo 'no verdict')"   "read out/8/verify/verify-x86_64-test-0.log"

#---------------------------------------------------------------------------#
# 9c. A lagging db_server that only drops a package: its database differs from
#     the promoted one with no package built earlier or later, so nothing says
#     it is newer. Listed first, it would win; the promoted database, still
#     served by the other db_server, is kept instead.
#---------------------------------------------------------------------------#
build two test-b
mkdir -p "$work/targets-lag"
{
  grep -v '^db_server' "$work/targets/x86_64-test.conf"
  # shellcheck disable=SC2016 # $arch and $repo are the target file's, not the shell's
  printf 'db_server = http://127.0.0.1:%s/$arch/test-b\ndb_server = http://127.0.0.1:%s/$arch/$repo\n' "$UP_PORT" "$UP_PORT"
} > "$work/targets-lag/x86_64-test.conf"
rc=0
TARGETS_DIR="$work/targets-lag" "$REPO_ROOT/scripts/plan" "$work/out/lag" > "$work/out/lag.log" 2>&1 || rc=$?
check "a lagging db_server that only drops a package does not move latest" current \
  "$(cat "$work/out/lag/x86_64-test/state" 2> /dev/null || echo "no state, plan exit $rc")" "read out/lag.log"

#---------------------------------------------------------------------------#
# 10. What the wrapper must refuse, served by a plain web server standing in
#    for a registry that lies: a manifest whose bytes are not the digest the
#    URL pins, a manifest with two layers of the same name, and a package
#    manifest with no signature layer.
#---------------------------------------------------------------------------#
fake="$work/upstream/v2/fake/repo/manifests"
mkdir -p "$fake"
honest='{"schemaVersion":2,"mediaType":"application/vnd.oci.image.manifest.v1+json","layers":[]}'
pinned="$(printf '%s' "$honest" | sha256sum | cut -d ' ' -f 1)"
printf '%s' '{"schemaVersion":2,"mediaType":"application/vnd.oci.image.manifest.v1+json","layers":[{"mediaType":"x","digest":"sha256:0000000000000000000000000000000000000000000000000000000000000000","size":1,"annotations":{"org.opencontainers.image.title":"test.db"}}]}' \
  > "$fake/sha256:$pinned"
printf '%s' '{"schemaVersion":2,"mediaType":"application/vnd.oci.image.manifest.v1+json","layers":[{"mediaType":"x","digest":"sha256:0000000000000000000000000000000000000000000000000000000000000000","size":1,"annotations":{"org.opencontainers.image.title":"test.db"}},{"mediaType":"x","digest":"sha256:1111111111111111111111111111111111111111111111111111111111111111","size":1,"annotations":{"org.opencontainers.image.title":"test.db"}}]}' \
  > "$fake/latest"
nosig_tag="$("$REPO_ROOT/client/pacman-oci" --tag 'nosig-1-1-any.pkg.tar.zst')"
printf '%s' '{"schemaVersion":2,"mediaType":"application/vnd.oci.image.manifest.v1+json","layers":[{"mediaType":"application/vnd.pkgforge.archlinux.pkg.v1","digest":"sha256:0000000000000000000000000000000000000000000000000000000000000000","size":1,"annotations":{"org.opencontainers.image.title":"nosig-1-1-any.pkg.tar.zst"}}]}' \
  > "$fake/$nosig_tag"

refuses() {
  local label="$1" url="$2" want="$3" rc=0
  "$REPO_ROOT/client/pacman-oci" "$work/refuse.part" "$url" > /dev/null 2> "$work/refuse.err" || rc=$?
  if [ "$rc" -eq 1 ] && { [ -z "$want" ] || grep -q -- "$want" "$work/refuse.err"; } && [ ! -e "$work/refuse.part" ]; then
    ok "the wrapper refuses $label"
  else
    fail "the wrapper refuses $label" "exit $rc" "stderr: $(cat "$work/refuse.err")" "reproduce: client/pacman-oci out.part '$url'"
  fi
}
refuses "a manifest whose bytes are not the pinned digest" \
  "oci+http://127.0.0.1:$UP_PORT/fake/repo@sha256:$pinned/test.db" "another digest"
refuses "a manifest with two layers of the same name" \
  "oci+http://127.0.0.1:$UP_PORT/fake/repo/test.db" "more than one layer"
refuses "a package manifest with no signature layer, loudly" \
  "oci+http://127.0.0.1:$UP_PORT/fake/repo/nosig-1-1-any.pkg.tar.zst.sig" "pacman tries no other server"

# A manifest far larger than any real one: curl stops reading at 64 KiB and the
# file falls through at once, rather than leaving awk to parse it while pacman
# waits.
awk 'BEGIN { printf "{\"schemaVersion\":2,\"layers\":["; for (i = 0; i < 1000000; i++) printf "%s1", (i ? "," : ""); print "]}" }' > "$fake/huge"
started_at="$(date +%s)"
refuses "a manifest over 64 KiB, quickly" "oci+http://127.0.0.1:$UP_PORT/fake/repo:huge/test.db" "Maximum file size exceeded"
check "the oversized manifest is given up within 20 seconds" 1 "$(( $(date +%s) - started_at < 20 ? 1 : 0 ))"   "time client/pacman-oci out.part oci+http://.../fake/repo:huge/test.db"

# serve_layer TAG TITLE BYTES_FILE DIGEST SIZE: a one-layer manifest at TAG
# whose descriptor says DIGEST and SIZE, and BYTES_FILE served as that blob
blobs="$work/upstream/v2/fake/repo/blobs"
mkdir -p "$blobs"
serve_layer() {
  jq -cn --arg t "$2" --arg d "sha256:$4" --argjson s "$5" \
    '{schemaVersion: 2, mediaType: "application/vnd.oci.image.manifest.v1+json", layers: [{mediaType: "x", digest: $d, size: $s, annotations: {"org.opencontainers.image.title": $t}}]}' \
    > "$fake/$1"
  cp "$3" "$blobs/sha256:$4"
}
printf 'the bytes the manifest names\n' > "$work/right"
right="$(sha256sum "$work/right" | cut -d ' ' -f 1)"
serve_layer wrongsize test.db "$work/right" "$right" 999
refuses "a blob whose size is not its descriptor's" \
  "oci+http://127.0.0.1:$UP_PORT/fake/repo:wrongsize/test.db" "the manifest says 999"
printf 'other bytes of the same length\n' > "$work/tampered"
serve_layer tampered test.db "$work/tampered" "$right" "$(wc -c < "$work/tampered" | tr -d ' ')"
refuses "a blob whose sha256 is not its descriptor's" \
  "oci+http://127.0.0.1:$UP_PORT/fake/repo:tampered/test.db" "has sha256"

# A database signature is read from the manifest of the database beside it.
mkdir -p "$work/pair"
printf 'the database pacman holds\n' > "$work/pair/test.db"
held_hex="$(sha256sum "$work/pair/test.db" | cut -d ' ' -f 1)"
printf 'its signature\n' > "$work/pair-sig"
sig_hex="$(sha256sum "$work/pair-sig" | cut -d ' ' -f 1)"
jq -cn --arg d "sha256:$held_hex" --argjson ds "$(wc -c < "$work/pair/test.db" | tr -d ' ')" \
  --arg g "sha256:$sig_hex" --argjson gs "$(wc -c < "$work/pair-sig" | tr -d ' ')" \
  '{schemaVersion: 2, mediaType: "application/vnd.oci.image.manifest.v1+json", layers: [
     {mediaType: "x", digest: $d, size: $ds, annotations: {"org.opencontainers.image.title": "test.db"}},
     {mediaType: "application/pgp-signature", digest: $g, size: $gs, annotations: {"org.opencontainers.image.title": "test.db.sig"}}]}' \
  > "$fake/db-$held_hex"
cp "$work/pair-sig" "$blobs/sha256:$sig_hex"
rc=0
"$REPO_ROOT/client/pacman-oci" "$work/pair/test.db.sig.part" "oci+http://127.0.0.1:$UP_PORT/fake/repo/test.db.sig" 2> "$work/pair.err" || rc=$?
check "a database signature comes from the manifest of the database beside it" "0:its signature" \
  "$rc:$(cat "$work/pair/test.db.sig.part" 2> /dev/null)" "client/pacman-oci DIR/test.db.sig.part oci+http://.../fake/repo/test.db.sig"

mkdir -p "$work/moved"
printf 'an older database\n' > "$work/moved/test.db"
serve_layer moved test.db "$work/right" "$right" "$(wc -c < "$work/right" | tr -d ' ')"
rc=0
PACMAN_OCI_DEBUG=1 "$REPO_ROOT/client/pacman-oci" "$work/moved/test.db.sig.part" "oci+http://127.0.0.1:$UP_PORT/fake/repo:moved/test.db.sig" 2> "$work/moved.err" || rc=$?
if [ "$rc" -eq 1 ] && grep -q 'moved on' "$work/moved.err" && [ ! -e "$work/moved/test.db.sig.part" ]; then
  ok "no signature is paired with a database the snapshot has moved on from"
else
  fail "no signature is paired with a database the snapshot has moved on from" "exit $rc" "$(cat "$work/moved.err")"
fi

summary
