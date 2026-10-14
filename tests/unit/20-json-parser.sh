#!/usr/bin/env bash
#
# The wrapper's JSON parser reads what a registry sends, so it must read every
# legal shape the same way and refuse anything that is not JSON.
#
# A parser that guessed would turn a truncated or hostile manifest into a
# digest, and the wrapper would fetch the wrong blob.
set -euo pipefail
# shellcheck source=../lib/harness.sh
. "$REPO_ROOT/tests/lib/harness.sh"

W="$REPO_ROOT/client/pacman-oci"
work="$(work_dir)"
trap 'rm -rf "$work"' EXIT

# parse NAME JSON -> flattened output in $work/NAME.out, exit code in $parse_rc
parse() {
  printf '%s' "$2" > "$work/$1.json"
  parse_rc=0
  "$W" --json "$work/$1.json" > "$work/$1.out" 2> "$work/$1.err" || parse_rc=$?
}

#---------------------------------------------------------------------------#
# A manifest as oras writes it, compact, and the same manifest pretty-printed
# with its keys in another order. Both must flatten to the same lines.
#---------------------------------------------------------------------------#
compact='{"schemaVersion":2,"mediaType":"application/vnd.oci.image.manifest.v1+json","artifactType":"application/vnd.pkgforge.archlinux.package.v1","config":{"mediaType":"application/vnd.oci.empty.v1+json","digest":"sha256:44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a","size":2,"data":"e30="},"layers":[{"mediaType":"application/vnd.pkgforge.archlinux.pkg.v1","digest":"sha256:41cf0bb5df14e18f7fb868a97da3feb7c4127fba99bb332ad54b14322faac1b1","size":84690,"annotations":{"org.opencontainers.image.title":"zlib-1:1.3.2-3-x86_64.pkg.tar.zst"}},{"mediaType":"application/pgp-signature","digest":"sha256:0000000000000000000000000000000000000000000000000000000000000001","size":119,"annotations":{"org.opencontainers.image.title":"zlib-1:1.3.2-3-x86_64.pkg.tar.zst.sig"}}],"annotations":{"org.opencontainers.image.created":"2026-10-13T00:00:00Z"}}'
pretty='{
  "layers": [
    {
      "annotations": { "org.opencontainers.image.title": "zlib-1:1.3.2-3-x86_64.pkg.tar.zst" },
      "size": 84690,
      "digest": "sha256:41cf0bb5df14e18f7fb868a97da3feb7c4127fba99bb332ad54b14322faac1b1",
      "mediaType": "application/vnd.pkgforge.archlinux.pkg.v1"
    },
    {
      "annotations": {
        "org.opencontainers.image.title": "zlib-1:1.3.2-3-x86_64.pkg.tar.zst.sig"
      },
      "size": 119,
      "digest": "sha256:0000000000000000000000000000000000000000000000000000000000000001",
      "mediaType": "application/pgp-signature"
    }
  ],
	"annotations" : {"org.opencontainers.image.created" : "2026-10-13T00:00:00Z"},
  "config": {"data": "e30=", "size": 2, "digest": "sha256:44136fa355b3678a1146ad16f7e8649e94fb4fc21fe77e8310c060f61caaff8a", "mediaType": "application/vnd.oci.empty.v1+json"},
  "artifactType": "application/vnd.pkgforge.archlinux.package.v1",
  "mediaType": "application/vnd.oci.image.manifest.v1+json",
  "schemaVersion": 2
}'
parse compact "$compact"
parse pretty "$pretty"
check "a compact manifest parses" 0 "$parse_rc" "client/pacman-oci --json FILE"
check "compact and pretty, keys reordered, flatten to the same lines" \
  "$(sort "$work/compact.out")" "$(sort "$work/pretty.out")" \
  "diff <(sort compact.out) <(sort pretty.out)"
check "the layer digest is at its pointer" \
  "sha256:41cf0bb5df14e18f7fb868a97da3feb7c4127fba99bb332ad54b14322faac1b1" \
  "$(awk -F '\t' '$1 == "/layers/0/digest" { print $2 }' "$work/compact.out")" \
  "client/pacman-oci --json FILE | grep /layers/0/digest"
check "the layer title is at its pointer" \
  "zlib-1:1.3.2-3-x86_64.pkg.tar.zst.sig" \
  "$(awk -F '\t' '$1 == "/layers/1/annotations/org.opencontainers.image.title" { print $2 }' "$work/compact.out")" \
  "client/pacman-oci --json FILE | grep /layers/1/annotations"

#---------------------------------------------------------------------------#
# Every scalar shape, escapes and pointer escaping.
#---------------------------------------------------------------------------#
BS="\\"
parse shapes '{"s":"a\"b\\c\/d","u":"caf'"$BS"'u00e9","k/e~y":1,"n":-0.5e-3,"t":true,"f":false,"z":null,"e":{},"a":[],"aa":[[1,[2]],{"x":[]}]}'
check "every scalar shape parses" 0 "$parse_rc" "client/pacman-oci --json FILE"
expected="$(printf '%s\n' \
  $'/s\ta"b\\c/d' \
  $'/u\tcaf\\u00e9' \
  $'/k~1e~0y\t1' \
  $'/n\t-0.5e-3' \
  $'/t\ttrue' \
  $'/f\tfalse' \
  $'/z\tnull' \
  $'/aa/0/0\t1' \
  $'/aa/0/1/0\t2')"
check "scalars, escapes kept escaped, ~ and / escaped in pointers" "$expected" "$(cat "$work/shapes.out")" \
  "client/pacman-oci --json FILE"

#---------------------------------------------------------------------------#
# Not JSON. Each must be refused with exit 3.
#---------------------------------------------------------------------------#
deep="$(printf '%*s' 40 '' | tr ' ' '[')1$(printf '%*s' 40 '' | tr ' ' ']')"
while IFS='|' read -r label text; do
  parse refused "$text"
  check "refused: $label" 3 "$parse_rc" "printf '%s' '$text' > f; client/pacman-oci --json f; echo \$?"
done <<EOF
empty input|
truncated object|{"a":
trailing comma|{"a":1,}
single quotes|{'a':1}
bare word|{"a":nope}
unterminated string|{"a":"b}
trailing data|{"a":1} x
two documents|{} {}
bad escape|{"a":"\q"}
bad unicode escape|{"a":"\u12"}
leading zero|{"a":01}
missing colon|{"a" 1}
an escaped newline, which could forge an output line|{"a":"x\ny"}
an escaped tab, which could forge an output field|{"a":"x\ty"}
a unicode control character|{"a":"x\u0001y"}
the last unicode control character|{"a":"x\u001fy"}
nested 40 deep|$deep
EOF

printf '{"a":"x\001y"}' > "$work/ctl.json"
rc=0
"$W" --json "$work/ctl.json" > /dev/null 2> "$work/ctl.err" || rc=$?
check "refused: a raw control character inside a string" 3 "$rc" "printf '{\"a\":\"x\\001y\"}' > f; client/pacman-oci --json f"

summary
