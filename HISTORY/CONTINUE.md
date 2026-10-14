# Continue here

What anyone picking this repository up needs first: the conventions, where
things stand, and what is left.

## Conventions

- One squashed commit per piece of work on `main`, by the maintainer's own
  identity. No co-author or generated-by lines.
- Scripts have no extension, are executable in the git index (except
  `scripts/lib.sh`, which is sourced), start with `set -euo pipefail`, and say in
  their header what they do, how to call them and what their exit codes mean.
  `client/pacman-oci` is POSIX sh and is tested under bash, dash and busybox.
- A failure is never hidden: no `|| true`, no `2>/dev/null` on anything that
  matters, no `set +e`, no `continue-on-error`. An exit code is captured as
  `rc=0; cmd || rc=$?`. Every curl has a connect deadline and a transfer or
  stall deadline; every oras call runs under `timeout`. `tests/static/30` checks
  all of it.
- Every failure message says what was measured and how to reproduce it. A
  script that sources `scripts/lib.sh` also reports, through an ERR trap, the
  command that ended it under `set -e`, so no exit is silent.
- Every test has been seen to fail: `HISTORY/tests-seen-to-fail.md`.
- Docs: no em dashes, no marketing adjectives, and only the markers ⛔ ⭐ ⚠.

## Where things stand (2026-10-14)

- x86_64 core is mirrored to `ghcr.io/pkgforge-dev/mirror-archlinux/x86_64/core`
  every three hours, verified by pacman through the wrapper before promotion.
  The first promotion from `main` was run 38490975315 on 2026-10-14: `latest`
  and `2026.10.14` name the same snapshot, and a stock Arch pacman with it as
  core's only Server ran `-Sy` in 4.0 s and `-S nano` in 5.1 s from a
  residential network.
  The package is public: the organisation creates packages public.
- Tests: the static suite (shellcheck, actionlint, seven policy files), the unit
  suite under bash and gawk, dash and mawk, and busybox, and the integration
  suite, which drives the whole mirror against a local registry and installs
  through the wrapper with and without `DownloadUser`. Every test has been seen
  to fail (`HISTORY/tests-seen-to-fail.md`).
- The design was reviewed before it was built, and the implementation after
  (`HISTORY/design.md`, both review sections); every confirmed finding is fixed
  and tested.
- docker-archlinux is unchanged. Nothing reads the mirror yet but its own tests.

## Maintainer actions

Done 2026-10-13, with the maintainer's approval:

- `default_workflow_permissions = read`, `can_approve_pull_request_reviews = false`.
- `sha_pinning_required = true`: only actions pinned by commit run.

Left to the maintainer:

- A GHCR package created by the workflow may come out private, and GitHub has
  no API to change that. `visibility-<target>` opens with the settings link
  when it does; everything is pushed and verified meanwhile.
- `replaced-<target>`: a file whose tag already holds other bytes. Arch never
  republishes a filename with new bytes, so this means something unusual
  upstream or on the registry. The issue names the file and both digests.
- Renovate proposes digest updates for the verify image and the test images,
  and action updates weekly; nothing merges on its own here.

## Phase 2, in order

1. **ppc.** Add `powerpc64le-base`, `powerpc64le-base-any` and the powerpc
   and powerpc64 equivalents with `db_signed = yes` (below), and a verify
   platform for them (binfmt and QEMU on the runner, which the ubuntu image
   lacks).
2. **`db_signed = yes`.** Plan already refuses a database whose `.sig` answers
   anything but 404, and keeps the `.sig` it finds. Still to build when the
   first signed target arrives: refuse a missing `.sig` (done in plan), check
   it with the pinned keyring before staging, verify with `DatabaseRequired`
   (done in verify-batch), and tell that repository's consumers to set it.
   Measure how often a consumer meets the `.db` and `.db.sig` race before
   adding any pinning to the wrapper.
3. **docker-archlinux.** Decide with the maintainer whether images enable the
   `XferCommand` for every repository, only for repositories whose upstream is
   blocked, or only in the build stage. A global one costs about 2 s per
   repository per `-Sy` and makes downloads sequential (HISTORY/design.md).
   Add the mirror's `latest` age to docker-archlinux's freshness check, so a
   schedule stop here is seen from there too.
4. **x86_64 extra.** 107.6 GiB, 15041 files: about 20 shards at the current
   limits, and probably two runs, since upstream supersedes files during a long
   seed. Its keyring is in core: add a `keyring_from = x86_64-core` key that puts
   the mirrored core into verify's pacman.conf.
5. **A staleness rule for targets a runner cannot read**, where the watchdog
   cannot compare with upstream: the age of `fetched` alone.

## Open measurements

`HISTORY/design.md`, "Open, to be measured".
