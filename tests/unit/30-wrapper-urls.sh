#!/usr/bin/env bash
#
# The wrapper turns pacman's URL into exactly one manifest request, and refuses
# a URL it cannot read before it touches the network.
#
# Port 9 on the loopback refuses connections at once, so every accepted URL
# fails fast after printing the request it would have made, and nothing here
# needs a network.
set -euo pipefail
# shellcheck source=../lib/harness.sh
. "$REPO_ROOT/tests/lib/harness.sh"

W="$REPO_ROOT/client/pacman-oci"
work="$(work_dir)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$work/tmp"
export TMPDIR="$work/tmp"

D64=41cf0bb5df14e18f7fb868a97da3feb7c4127fba99bb332ad54b14322faac1b1
HASHTAG="fn-$(printf '%s' 'a;b-1-1-any.pkg.tar.zst' | sha256sum | cut -d ' ' -f 1)"
BSTAG="fn-$(printf '%s' 'a\b-1-1-any.pkg.tar.zst' | sha256sum | cut -d ' ' -f 1)"

# request URL -> the first GET line the wrapper printed, and its exit code.
# OUTPUT exists beforehand, as a .part from an earlier attempt would, so every
# failing request also shows whether the wrapper removes it.
request() {
  req_rc=0
  printf 'a stale partial download\n' > "$work/out.part"
  PACMAN_OCI_DEBUG=1 "$W" "$work/out.part" "$1" > /dev/null 2> "$work/err" || req_rc=$?
  req_line="$(sed -n 's/^pacman-oci: GET \([^ ]*\) .*/\1/p' "$work/err" | sed -n 1p)"
}

while IFS='|' read -r label url want; do
  request "$url"
  check "$label" "$want" "$req_line" "PACMAN_OCI_DEBUG=1 client/pacman-oci out.part '$url'"
  check "$label: no answer is exit 1, so pacman tries the next Server" 1 "$req_rc" \
    "client/pacman-oci out.part '$url'; echo \$?"
done <<EOF
the database from latest|oci+http://127.0.0.1:9/ns/mirror/x86_64/core/core.db|http://127.0.0.1:9/v2/ns/mirror/x86_64/core/manifests/latest
the files database from latest|oci+http://127.0.0.1:9/ns/mirror/x86_64/core/core.files|http://127.0.0.1:9/v2/ns/mirror/x86_64/core/manifests/latest
the database from a snapshot tag|oci+http://127.0.0.1:9/ns/mirror/x86_64/core:2026.10.13/core.db|http://127.0.0.1:9/v2/ns/mirror/x86_64/core/manifests/2026.10.13
the database from a digest|oci+http://127.0.0.1:9/ns/mirror/x86_64/core@sha256:$D64/core.db|http://127.0.0.1:9/v2/ns/mirror/x86_64/core/manifests/sha256:$D64
a package by its own tag|oci+http://127.0.0.1:9/ns/mirror/x86_64/core/zlib-1:1.3.2-3-x86_64.pkg.tar.zst|http://127.0.0.1:9/v2/ns/mirror/x86_64/core/manifests/zlib-1_c1.3.2-3-x86_64.pkg.tar.zst
a package signature by the package's tag|oci+http://127.0.0.1:9/ns/mirror/x86_64/core/zlib-1:1.3.2-3-x86_64.pkg.tar.zst.sig|http://127.0.0.1:9/v2/ns/mirror/x86_64/core/manifests/zlib-1_c1.3.2-3-x86_64.pkg.tar.zst
a package ignores the snapshot tag|oci+http://127.0.0.1:9/ns/mirror/x86_64/core:2026.10.13/gcc-libs-15.2.1+r22-1-x86_64.pkg.tar.zst|http://127.0.0.1:9/v2/ns/mirror/x86_64/core/manifests/gcc-libs-15.2.1_pr22-1-x86_64.pkg.tar.zst
oci:// is https|oci://127.0.0.1:9/ns/mirror/x86_64/core/core.db|https://127.0.0.1:9/v2/ns/mirror/x86_64/core/manifests/latest
an uncompressed package|oci+http://127.0.0.1:9/ns/mirror/x86_64/core/tiny-1-1-any.pkg.tar|http://127.0.0.1:9/v2/ns/mirror/x86_64/core/manifests/tiny-1-1-any.pkg.tar
a name outside the tag alphabet goes to the hash tag|oci+http://127.0.0.1:9/ns/mirror/x86_64/core/a;b-1-1-any.pkg.tar.zst|http://127.0.0.1:9/v2/ns/mirror/x86_64/core/manifests/$HASHTAG
a backslash in the name goes to the hash tag|oci+http://127.0.0.1:9/ns/mirror/x86_64/core/a\b-1-1-any.pkg.tar.zst|http://127.0.0.1:9/v2/ns/mirror/x86_64/core/manifests/$BSTAG
a database signature with no database beside it reads the URL tag|oci+http://127.0.0.1:9/ns/mirror/x86_64/core:2026.10.13/core.db.sig|http://127.0.0.1:9/v2/ns/mirror/x86_64/core/manifests/2026.10.13
EOF

#---------------------------------------------------------------------------#
# A database signature is read from the manifest of the database pacman took
# moments before, found by that file's content, so a promotion between the two
# requests cannot pair one snapshot's database with another's signature.
#---------------------------------------------------------------------------#
mkdir -p "$work/download-AbC123"
printf 'database bytes\n' > "$work/download-AbC123/core.db"
printf 'files bytes\n' > "$work/download-AbC123/core.files"
for pair in db files; do
  rc=0
  PACMAN_OCI_DEBUG=1 "$W" "$work/download-AbC123/core.$pair.sig.part" \
    "oci+http://127.0.0.1:9/ns/mirror/x86_64/core/core.$pair.sig" > /dev/null 2> "$work/err" || rc=$?
  want="http://127.0.0.1:9/v2/ns/mirror/x86_64/core/manifests/$pair-$(sha256sum "$work/download-AbC123/core.$pair" | cut -d ' ' -f 1)"
  check "core.$pair.sig is read by the content of the core.$pair beside it" "$want" \
    "$(sed -n 's/^pacman-oci: GET \([^ ]*\) .*/\1/p' "$work/err" | sed -n 1p)" \
    "PACMAN_OCI_DEBUG=1 client/pacman-oci DIR/core.$pair.sig.part URL, with DIR/core.$pair present"
done

#---------------------------------------------------------------------------#
# Refused before any request: exit 1 and no GET line.
#---------------------------------------------------------------------------#
while IFS='|' read -r label url; do
  request "$url"
  check "refused, $label" "1:" "$req_rc:$req_line" "PACMAN_OCI_DEBUG=1 client/pacman-oci out.part '$url'"
done <<'EOF'
no repository|oci://ghcr.io/core.db
no file|oci://ghcr.io/ns/repo/
an upper case repository|oci://ghcr.io/NS/repo/core.db
a repository with a double dot|oci://ghcr.io/ns/a..b/core.db
a tag with a bad character|oci://ghcr.io/ns/repo:bad!tag/core.db
a digest that is not sha256 hex|oci://ghcr.io/ns/repo@sha256:xyz/core.db
a space in the file|oci://ghcr.io/ns/repo/a b.pkg.tar.zst
a tag longer than 128 characters|oci://ghcr.io/ns/repo:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/core.db
a host with a path trick|oci://gh cr.io/ns/repo/core.db
EOF

# A TMPDIR the download user cannot write, which DownloadUser makes possible:
# the wrapper falls back to the directory OUTPUT is in, and still asks.
rc=0
TMPDIR="$work/no-such-dir" PACMAN_OCI_DEBUG=1 "$W" "$work/out.part" "oci+http://127.0.0.1:9/ns/mirror/x86_64/core/core.db" > /dev/null 2> "$work/err" || rc=$?
check "an unusable TMPDIR falls back to OUTPUT's directory" "http://127.0.0.1:9/v2/ns/mirror/x86_64/core/manifests/latest" \
  "$(sed -n 's/^pacman-oci: GET \([^ ]*\) .*/\1/p' "$work/err" | sed -n 1p)" "TMPDIR=/nonexistent client/pacman-oci out.part URL"

#---------------------------------------------------------------------------#
# Usage errors are exit 2, so they are never mistaken for "not here".
#---------------------------------------------------------------------------#
rc=0
"$W" only-one > /dev/null 2>&1 || rc=$?
check "one argument is a usage error" 2 "$rc" "client/pacman-oci only-one; echo \$?"
rc=0
"$W" '' 'oci://ghcr.io/a/b/c.db' > /dev/null 2>&1 || rc=$?
check "an empty OUTPUT is a usage error" 2 "$rc" "client/pacman-oci '' oci://ghcr.io/a/b/c.db; echo \$?"

#---------------------------------------------------------------------------#
# A URL that is not oci:// is an ordinary download, which is how the upstream
# Servers after the registry keep working. file:// needs no network.
#---------------------------------------------------------------------------#
printf 'plain bytes\n' > "$work/source.db"
rc=0
"$W" "$work/copy.part" "file://$work/source.db" > /dev/null 2>&1 || rc=$?
check "a file:// URL is downloaded as is" "0:plain bytes" "$rc:$(cat "$work/copy.part")" \
  "client/pacman-oci copy.part file://\$PWD/source.db"
rc=0
"$W" "$work/missing.part" "file://$work/no-such-file" > /dev/null 2>&1 || rc=$?
if [ "$rc" -ne 0 ]; then
  ok "a missing plain file is a failure, so pacman tries the next Server"
else
  fail "a missing plain file is a failure, so pacman tries the next Server" "exit 0" \
    "reproduce: client/pacman-oci missing.part file:///no-such-file; echo \$?"
fi

#---------------------------------------------------------------------------#
# The wrapper is POSIX sh. dash is the strictest common shell; when it is
# here, the same URL must give the same request under it.
#---------------------------------------------------------------------------#
if command -v dash > /dev/null 2>&1; then
  rc=0
  PACMAN_OCI_DEBUG=1 dash "$W" "$work/out.part" "oci+http://127.0.0.1:9/ns/mirror/x86_64/core/zlib-1:1.3.2-3-x86_64.pkg.tar.zst" > /dev/null 2> "$work/err" || rc=$?
  check "under dash: the same request" \
    "http://127.0.0.1:9/v2/ns/mirror/x86_64/core/manifests/zlib-1_c1.3.2-3-x86_64.pkg.tar.zst" \
    "$(sed -n 's/^pacman-oci: GET \([^ ]*\) .*/\1/p' "$work/err" | sed -n 1p)" \
    "dash client/pacman-oci out.part URL"
  check "under dash: the same tags" "$("$W" --tags < "$REPO_ROOT/tests/fixtures/filenames.txt" | sha256sum)" \
    "$(dash "$W" --tags < "$REPO_ROOT/tests/fixtures/filenames.txt" | sha256sum)" \
    "diff <(client/pacman-oci --tags < f) <(dash client/pacman-oci --tags < f)"
else
  diag "dash is not installed here; the POSIX check runs where it is (ubuntu runners have it as /bin/sh)"
  ok "skipped: dash not installed"
fi

leftover="$(find "$work/tmp" -mindepth 1 | wc -l | tr -d ' ')"
check "no temporary file is left in TMPDIR" 0 "$leftover" "ls \$TMPDIR after client/pacman-oci"
request "oci+http://127.0.0.1:9/ns/mirror/x86_64/core/core.db"
check "a failed attempt removes the .part it was given" "1:absent" \
  "$req_rc:$([ -e "$work/out.part" ] && echo present || echo absent)" "client/pacman-oci out.part URL; ls out.part"

summary
