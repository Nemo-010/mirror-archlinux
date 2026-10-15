#!/usr/bin/env bash
#
# The fetcher CLI: which client each call picks, the fallback from one client
# to the next, the structural check of the body, and the version resolver.
# Everything runs against a curl stand-in and a faked curl-impersonate, so no
# browser and no network are needed.
set -euo pipefail
# shellcheck source=../lib/harness.sh
. "$REPO_ROOT/tests/lib/harness.sh"

work="$(work_dir)"
trap 'rm -rf "$work"' EXIT

# A copy of the fetchers tree, so the browser clients can be left out and the
# curl-impersonate client replaced by a stand-in.
cp -r "$REPO_ROOT/fetchers" "$work/fetchers"
mkdir -p "$work/fetchers/curl-impersonate"
cat > "$work/fetchers/curl-impersonate/available" << 'EOF'
#!/usr/bin/env bash
exit 0
EOF
cat > "$work/fetchers/curl-impersonate/fetch.sh" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
url="$1"
out="$2"
printf '%s\n' "$url" >> "${FAKE_CI_CALLS:?}"
if [ "${FAKE_CI_RC:-0}" -ne 0 ]; then
  exit "${FAKE_CI_RC}"
fi
cp "${FAKE_CI_BODY:?}" "$out"
exit 0
EOF
chmod 0755 "$work/fetchers/curl-impersonate/available" "$work/fetchers/curl-impersonate/fetch.sh"

# The curl stand-in.
mkdir -p "$work/bin" "$work/fakecurl"
cp "$REPO_ROOT/tests/fixtures/fetcher/fake-curl" "$work/bin/curl"
chmod 0755 "$work/bin/curl"
export PATH="$work/bin:$PATH"
export FAKE_CURL_DIR="$work/fakecurl"

# Bodies. The curl stand-in reads its files from FAKE_CURL_DIR, so they live
# there.
mkdir -p "$work/db/p-1"
printf 'p\tp\t1-1\tany\t%s\t10\t1700000000\t\n' "$(printf 'p' | sha256sum | cut -d ' ' -f 1)" > "$work/db/p-1/desc"
(cd "$work/db" && tar -czf "$work/fakecurl/good.db" -- .)
printf 'this is not a tar archive\n' > "$work/fakecurl/notatar"
printf '\x88\x01\x00' > "$work/fakecurl/good.sig"
printf '\x00\x01\x00' > "$work/fakecurl/bad.sig"
printf 'denied\n' > "$work/fakecurl/denied.html"
jq -n '{tag_name: "v9.9.9"}' > "$work/fakecurl/release.json"
good_db="$work/fakecurl/good.db"
: > "$work/ci.calls"

# A database whose desc member comes before a listing far larger than a pipe
# buffer: a reader that stops at the first match would kill tar and fail the
# whole check.
mkdir -p "$work/many/aaa-1" "$work/many/bulk"
printf 'aaa\taaa\t1-1\tany\t%s\t10\t1700000000\t\n' "$(printf 'aaa' | sha256sum | cut -d ' ' -f 1)" > "$work/many/aaa-1/desc"
i=1
while [ "$i" -le 4000 ]; do
  printf 'x\n' > "$work/many/bulk/package-$(printf '%05d' "$i")-1.0.0"
  i=$((i + 1))
done
(cd "$work/many" && tar --sort=name -czf "$work/fakecurl/many.db" -- .)

# A fresh behaviour for the curl stand-in. default CODE BODY
behaviour() {
  printf '%s %s\n' "$1" "$2" > "$work/fakecurl/default"
  : > "$work/fakecurl/rules"
  : > "$work/fakecurl/calls"
}
rule() {
  printf '%s %s %s\n' "$1" "$2" "$3" >> "$work/fakecurl/rules"
}

# run CLIENT-ARGS... -> runs the fetchers copy, with its own cache and summary
run() {
  FETCHER_CACHE="$work/cache" FETCHER_SUMMARY="$work/summary.tsv" \
    FAKE_CI_BODY="${FAKE_CI_BODY:-$good_db}" FAKE_CI_CALLS="$work/ci.calls" \
    "$work/fetchers/fetcher.sh" "$@"
}

#---------------------------------------------------------------------------#
# Which clients can run, and what --list says
#---------------------------------------------------------------------------#
got="$("$work/fetchers/fetcher.sh" --list | tr '\n' ' ' | sed 's/ $//')"
check "fetcher --list names the clients that answer here" "curl curl-impersonate" "$got" \
  "fetchers/fetcher.sh --list"

#---------------------------------------------------------------------------#
# A host that answers curl: curl is used, once, and the host is remembered
#---------------------------------------------------------------------------#
behaviour 200 good.db
rc=0
run --expect db https://fast.test/base.db "$work/fast.db" > /dev/null 2>&1 || rc=$?
check "a host that answers curl is read" "0 $(sha256sum "$good_db" | cut -d ' ' -f 1)" \
  "$rc $(sha256sum "$work/fast.db" | cut -d ' ' -f 1)" \
  "fetchers/fetcher.sh --expect db https://fast.test/base.db OUT"
check "the client that read the host is remembered" curl "$(cat "$work/cache/hosts/fast.test" 2> /dev/null)" \
  "cat \$FETCHER_CACHE/hosts/fast.test"
check "curl read the host with one call" 1 "$(awk 'END { print NR + 0 }' "$work/fakecurl/calls")" \
  "cat \$FAKE_CURL_DIR/calls"
check "no curl-impersonate call was made" 0 "$(awk 'END { print NR + 0 }' "$work/ci.calls")" \
  "cat \$FAKE_CI_CALLS"

#---------------------------------------------------------------------------#
# A host that answers curl with an interstitial: curl-impersonate reads it,
# and the next call for the same host starts with it
#---------------------------------------------------------------------------#
behaviour 200 good.db
rule challenged 403 denied.html
: > "$work/ci.calls"
rc=0
run --expect db https://challenged.test/base.db "$work/challenged.db" > /dev/null 2>&1 || rc=$?
check "a 403 from curl falls back to curl-impersonate" "0 $(sha256sum "$good_db" | cut -d ' ' -f 1)" \
  "$rc $(sha256sum "$work/challenged.db" | cut -d ' ' -f 1)" \
  "fetchers/fetcher.sh --expect db https://challenged.test/base.db OUT"
check "the host is then remembered as curl-impersonate" curl-impersonate \
  "$(cat "$work/cache/hosts/challenged.test" 2> /dev/null)" "cat \$FETCHER_CACHE/hosts/challenged.test"
check "curl-impersonate read the host with one call" 1 "$(awk 'END { print NR + 0 }' "$work/ci.calls")" \
  "cat \$FAKE_CI_CALLS"
: > "$work/fakecurl/calls"
rc=0
run --expect db https://challenged.test/base.db "$work/challenged2.db" > /dev/null 2>&1 || rc=$?
check "the next call for that host starts at curl-impersonate" "0 0" \
  "$rc $(awk 'END { print NR + 0 }' "$work/fakecurl/calls")" \
  "the remembered client is tried first, so curl is not called again"

#---------------------------------------------------------------------------#
# A 404 is the server's answer, not a client that needs changing
#---------------------------------------------------------------------------#
behaviour 200 good.db
rule gone 404 denied.html
: > "$work/ci.calls"
rc=0
run --expect db https://host.test/gone/base.db "$work/gone.db" > /dev/null 2>&1 || rc=$?
check "a 404 ends the call with status 4" 4 "$rc" "fetchers/fetcher.sh --expect db URL OUT"
check "a 404 does not try a second client" 0 "$(awk 'END { print NR + 0 }' "$work/ci.calls")" \
  "cat \$FAKE_CI_CALLS"

#---------------------------------------------------------------------------#
# The structural check: a body that is not what was asked for is refused
#---------------------------------------------------------------------------#
behaviour 200 notatar
FAKE_CI_BODY="$work/fakecurl/notatar"
rc=0
run --expect db https://bad.test/base.db "$work/bad.db" > /dev/null 2>&1 || rc=$?
check "a body that is not a database is refused" 1 "$rc" \
  "fetchers/fetcher.sh --expect db URL OUT"
FAKE_CI_BODY="$good_db"
behaviour 200 many.db
rc=0
run --expect db https://many.test/base.db "$work/many.out" > /dev/null 2>&1 || rc=$?
check "a database with an early desc member is read" "0 $(sha256sum "$work/fakecurl/many.db" | cut -d ' ' -f 1)" \
  "$rc $(sha256sum "$work/many.out" | cut -d ' ' -f 1)" \
  "fetchers/fetcher.sh --expect db URL OUT"
behaviour 200 good.sig
rc=0
run --expect sig https://sig.test/x.sig "$work/x.sig" > /dev/null 2>&1 || rc=$?
check "an OpenPGP signature passes the sig check" 0 "$rc" "fetchers/fetcher.sh --expect sig URL OUT"
behaviour 200 bad.sig
rc=0
run --expect sig https://sig.test/x.sig "$work/y.sig" > /dev/null 2>&1 || rc=$?
check "a body that is not a signature packet is refused" 1 "$rc" \
  "fetchers/fetcher.sh --expect sig URL OUT"

#---------------------------------------------------------------------------#
# An explicit client list is used as given
#---------------------------------------------------------------------------#
behaviour 200 good.db
rc=0
run --client curl-impersonate --expect db https://only.test/base.db "$work/only.db" > /dev/null 2>&1 || rc=$?
check "an explicit --client is used" "0 0" "$rc $(awk 'END { print NR + 0 }' "$work/fakecurl/calls")" \
  "curl is left out when only curl-impersonate is named"

#---------------------------------------------------------------------------#
# The version resolver: the newest release, cached, and printed
#---------------------------------------------------------------------------#
rm -rf "$work/drift-cache"
behaviour 200 release.json
rule api.github.com 200 release.json
rc=0
out="$(FETCHER_CACHE="$work/drift-cache" "$REPO_ROOT/fetchers/drift.sh" --force --key curl-impersonate 2> /dev/null)" || rc=$?
check "drift reads the newest release tag" "0 curl-impersonate	v9.9.9" "$rc $(printf '%s' "$out" | tr -d '\n')" \
  "fetchers/drift.sh --force --key curl-impersonate"
rc=0
out="$(FETCHER_CACHE="$work/drift-cache" "$REPO_ROOT/fetchers/drift.sh" --key curl-impersonate 2> /dev/null)" || rc=$?
check "drift serves the value from its cache" "0 curl-impersonate	v9.9.9" "$rc $(printf '%s' "$out" | tr -d '\n')" \
  "fetchers/drift.sh --key curl-impersonate"

#---------------------------------------------------------------------------#
# The usage, the order, and a client name that no build defines
#---------------------------------------------------------------------------#
rc=0
help_out="$("$work/fetchers/fetcher.sh" --help 2>&1)" || rc=$?
check "--help names the options and exits 0" "0 1" \
  "$rc $(printf '%s\n' "$help_out" | awk '/--expect/ { n++ } END { print n + 0 }')" \
  "fetchers/fetcher.sh --help"

explain_out="$(FETCHER_CACHE="$work/cache" "$work/fetchers/fetcher.sh" --explain https://explain.test/a 2>&1)"
check "--explain names the order and the availability" "1 1" \
  "$(printf '%s\n' "$explain_out" | awk '/^order: curl/ { n++ } END { print n + 0 }') $(printf '%s\n' "$explain_out" | awk -F '\t' '$1 == "curl" && $2 == "available" { n++ } END { print n + 0 }')" \
  "fetchers/fetcher.sh --explain URL"

behaviour 200 good.db
: > "$work/fakecurl/calls"
rc=0
run --client bogus --expect any https://bogus.test/a "$work/bogus.out" > /dev/null 2>&1 || rc=$?
check "an unknown client is refused" 1 "$rc" "fetchers/fetcher.sh --client bogus URL OUT"
check "the refusal makes no request" 0 "$(awk 'END { print NR + 0 }' "$work/fakecurl/calls")" \
  "cat \$FAKE_CURL_DIR/calls"

#---------------------------------------------------------------------------#
# A body the caller already knows the digest of
#---------------------------------------------------------------------------#
behaviour 200 good.db
sha="$(sha256sum "$good_db" | cut -d ' ' -f 1)"
rc=0
run --client curl --no-cache --expect db --sha256 "$sha" https://sha.test/base.db "$work/sha.out" > /dev/null 2>&1 || rc=$?
check "a body with the asked sha256 passes" "0 $(sha256sum "$good_db" | cut -d ' ' -f 1)" \
  "$rc $(sha256sum "$work/sha.out" | cut -d ' ' -f 1)" \
  "fetchers/fetcher.sh --sha256 $sha --expect db URL OUT"
rc=0
run --client curl --no-cache --expect db --sha256 "$(printf '0%.0s' $(seq 1 64))" https://sha.test/base.db "$work/sha2.out" > /dev/null 2>&1 || rc=$?
check "a body with another sha256 is refused" 1 "$rc" \
  "fetchers/fetcher.sh --sha256 000...0 --expect db URL OUT"
rc=0
run --client curl --expect any --sha256 zz https://sha.test/base.db "$work/sha3.out" > /dev/null 2>&1 || rc=$?
check "--sha256 that is not 64 hex characters is refused" 1 "$rc" \
  "fetchers/fetcher.sh --sha256 zz URL OUT"

#---------------------------------------------------------------------------#
# A client that hangs is stopped within --timeout
#---------------------------------------------------------------------------#
cp "$work/fetchers/curl-impersonate/fetch.sh" "$work/ci-fast.sh"
cat > "$work/fetchers/curl-impersonate/fetch.sh" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
sleep 30
EOF
chmod 0755 "$work/fetchers/curl-impersonate/fetch.sh"
started=$SECONDS
rc=0
run --client curl-impersonate --no-cache --retries 1 --timeout 2 --expect any https://slow.test/a "$work/slow.out" > /dev/null 2>&1 || rc=$?
took=$((SECONDS - started))
check "a client that hangs is stopped within --timeout" "1 yes" \
  "$rc $([ "$took" -lt 15 ] && echo yes || echo "no, $took s")" \
  "fetchers/fetcher.sh --client curl-impersonate --timeout 2 URL OUT, against a client that sleeps 30 s"
cp "$work/ci-fast.sh" "$work/fetchers/curl-impersonate/fetch.sh"

#---------------------------------------------------------------------------#
# Every client is dispatched to its own program, not to another's
#---------------------------------------------------------------------------#
: > "$work/dispatch"
export FAKE_DISPATCH="$work/dispatch"
mkdir -p "$work/fetchers/playwright/venv/bin"
cat > "$work/bin/node" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'node %s\n' "$1" >> "${FAKE_DISPATCH:?}"
out="${@: -1}"
cp "${FAKE_CI_BODY:?}" "$out"
EOF
cat > "$work/fetchers/playwright/venv/bin/python" << 'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf 'python %s\n' "$1" >> "${FAKE_DISPATCH:?}"
out="${@: -1}"
cp "${FAKE_CI_BODY:?}" "$out"
EOF
chmod 0755 "$work/bin/node" "$work/fetchers/playwright/venv/bin/python"
for c in chromium cloak-browser playwright; do
  printf '#!/usr/bin/env bash\nexit 0\n' > "$work/fetchers/$c/available"
  chmod 0755 "$work/fetchers/$c/available"
done
behaviour 200 good.db
for c in chromium cloak-browser playwright; do
  rc=0
  run --client "$c" --no-cache --expect db "https://$c.test/base.db" "$work/$c.out" > /dev/null 2>&1 || rc=$?
  check "$c reads the body through its own program" "0 $(sha256sum "$good_db" | cut -d ' ' -f 1)" \
    "$rc $(sha256sum "$work/$c.out" | cut -d ' ' -f 1)" \
    "fetchers/fetcher.sh --client $c URL OUT"
done
check "chromium runs fetch.mjs through node" 1 \
  "$(awk '/^node .*chromium\/fetch\.mjs$/ { n++ } END { print n + 0 }' "$work/dispatch")" "cat \$FAKE_DISPATCH"
check "cloak-browser runs fetch.mjs through node" 1 \
  "$(awk '/^node .*cloak-browser\/fetch\.mjs$/ { n++ } END { print n + 0 }' "$work/dispatch")" "cat \$FAKE_DISPATCH"
check "playwright runs fetch.py through its venv python" 1 \
  "$(awk '/^python .*playwright\/fetch\.py$/ { n++ } END { print n + 0 }' "$work/dispatch")" "cat \$FAKE_DISPATCH"

summary
