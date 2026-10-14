# Tests seen to fail

⛔ A test that has never failed has not been shown to test anything. Each fault
below was injected into a fresh copy of the repository on 2026-10-13 or
2026-10-14, the test that must catch it was run, and it failed with the
assertion named. The tree itself was never changed. Every integration fault was
run again on 2026-10-14, after the fixture change below, and each was caught
again by the assertion named.

How each was run: copy the repository, replace one exact piece of text in one
file, run the one test file with `REPO_ROOT` set to the copy. Integration
faults ran with docker or podman and their own registry and upstream ports.

## client/pacman-oci

| fault | test | failed with |
| --- | --- | --- |
| a literal `_` before `p c a u` no longer escaped | unit/10-tag-encoding | `tag of a_pb-1-1-any.pkg.tar.zst` |
| upper case kept in tags, which GHCR folds together | unit/10-tag-encoding | `a name outside the mapping hashes: lshw-B.02.20-3-x86_64.pkg.tar.zst` |
| the 128 character tag limit off by one | unit/10-tag-encoding | `a name of 129 characters is hashed` |
| an escaped newline or tab accepted in a JSON string | unit/20-json-parser | `refused: an escaped newline, which could forge an output line` |
| data after the JSON document ignored | unit/20-json-parser | `refused: trailing data` |
| an uncompressed `.pkg.tar` read as a database | unit/30-wrapper-urls | `an uncompressed package` |
| a database signature read from the moving tag | unit/30-wrapper-urls | `core.db.sig is read by the content of the core.db beside it` |
| a failed attempt leaves its `.part` behind | unit/30-wrapper-urls | `a failed attempt removes the .part it was given` |
| a blob's sha256 no longer checked | integration/10-pipeline | `the wrapper refuses a blob whose sha256 is not its descriptor's` |

## scripts

| fault | test | failed with |
| --- | --- | --- |
| a tag holding other bytes is pushed over (decide_push) | unit/40-lib | `write-once: other bytes under this name are never overwritten` |
| mirror-file pushes over a tag holding other bytes | integration/10-pipeline | `a file whose bytes changed under its own name holds the target` |
| older and newer swapped in the behind rule | unit/40-lib | `core of 10-03 is not behind 10-02` |
| plan takes a database behind the promoted one | integration/10-pipeline | `an older upstream database is refused as behind` |
| a `/` allowed in a filename from a database | unit/40-lib | `db field check refuses a / alone, after a valid prefix` |
| staleness waits ten times too long | unit/40-lib | `stale: different, fetched longer ago than the tolerance` |
| an earlier snapshot may be promoted over a later one | unit/40-lib | `a later snapshot may be promoted` |
| promote no longer refuses an older snapshot | integration/10-pipeline | `promoting an older run's snapshot again is refused` |
| an item that left no result counts as pushed | unit/40-lib | `an item that left no result is counted as failed` |
| an unknown key in a target file ignored | unit/40-lib | `refused: an unknown key` |
| verify downloads and checks nothing | integration/10-pipeline | `verify fails it, and names the package` |
| plan lets a lagging db_server that only dropped a package win | integration/10-pipeline | `a lagging db_server that only drops a package does not move latest` |
| with no `%PGPSIG%`, the detached `.sig` is never fetched | integration/10-pipeline | `a database without %PGPSIG% stages` |
| the signature layer is not the database's `%PGPSIG%` (the decode loses its last base64 group) | integration/10-pipeline | `alpha-1:1.0+r2-1-any.pkg.tar.zst signature layer is its %PGPSIG%, decoded` |

## What the faults found

The fault for the detached `.sig` path was first caught by the first sync, not
by the scenario written for it: no fixture database carried `%PGPSIG%` at all.
pacman 7's `repo-add` embeds signatures only when given `--include-sigs`, so
the suite had driven only the detached path, while every package of Arch's core
carries `%PGPSIG%` (299 of 299, measured 2026-10-14). The fixture now passes
`--include-sigs`, and the suite asserts that its database carries a `%PGPSIG%`
for every package before it relies on it.

It found a second gap. With the decode broken, verify still passed: pacman 7.1
checks a package against the database's `%PGPSIG%`, yet still asks the wrapper
for its `.sig` and stores it in the cache unread (measured against the
promoted core, 2026-10-14), where a later `pacman -U` from the cache reads it.
Verify now compares every stored `.sig` with the decoded `%PGPSIG%`, and the
decode fault is refused there, before promotion.

## Policy

| fault | test | failed with |
| --- | --- | --- |
| an unquoted expansion in scripts/plan | static/10-shellcheck | `shellcheck -s bash scripts/plan` |
| a job reads an output that does not exist | static/20-actionlint | `actionlint .github/workflows/sync.yml` |
| a failure swallowed with `\|\| true` | static/30-failures-stay-visible | `scripts/stage hides no failure` |
| a curl call with no deadline | static/30-failures-stay-visible | `scripts/install-oras: every curl has a connect deadline and a transfer or stall deadline` |
| an oras call with no deadline | static/30-failures-stay-visible | `scripts/promote: every oras call has a deadline` |
| a script committed without its executable bit | static/40-executable-bits | `scripts/plan is mode 100755 in the index` |
| a job without timeout-minutes | static/50-workflow-policy | `.github/workflows/watchdog.yml: every job has timeout-minutes` |
| a dispatch input expanded inside a `run:` block | static/50-workflow-policy | `.github/workflows/sync.yml: no untrusted value is expanded inside a run: block` |
| an action pinned by tag | static/50-workflow-policy | `.github/workflows/ci.yml: every action is pinned by commit` |
| a call to the packages DELETE API | static/50-workflow-policy | `no script or workflow deletes a package or a version` |
| a pipeline that ends in a reader that stops early | static/35-pipeline-traps | `scripts/install-oras: no pipeline ends in a reader that stops early` |
| a verify image pinned without a tag | static/60-targets | `targets/x86_64-core.conf pins its verify image as name:tag@sha256` |

## Upstream faults the integration suite drives on every run

These are not code faults but hostile or broken inputs, built by
`tests/fixtures/build-repo` or served by a plain web server standing in for a
registry that lies. The suite fails if the mirror accepts any of them.

| input | must end as |
| --- | --- |
| an upstream database older than the promoted one | `behind`, latest unmoved |
| a file whose bytes change under its own name | `replaced`, the tag unmoved |
| a new file whose tag already holds other bytes | `replaced`, the tag unmoved |
| two db_servers each ahead of the other on one package | `held` |
| a db_server, listed first, that lags by one dropped package | `current`, latest unmoved |
| a database with a `%PGPSIG%` for every package, as core's | each signature layer is that `%PGPSIG%`, decoded |
| a database with no `%PGPSIG%` | each new package's signature layer is upstream's detached `.sig`, and pacman verifies against it |
| a package signed by a key nobody trusts | verify `failed` naming it, never promoted |
| an older run's stage promoted again | refused, latest unmoved |
| a manifest whose bytes are not the digest the URL pins | refused by the wrapper |
| a manifest with two layers of one name | refused by the wrapper |
| a package manifest with no signature layer | refused by the wrapper, loudly |
| a blob whose size, or sha256, is not its descriptor's | refused by the wrapper |
| a manifest over 64 KiB | given up within 20 s |
| a database signature whose snapshot moved on | not paired, the wrapper misses |
