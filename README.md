# mirror-archlinux

Arch Linux repositories stored on GHCR, and read by pacman through one small
shell script.

GitHub's runners are refused by a growing number of upstream mirrors: ArchPOWER
answers every datacentre address with a bot challenge, and docker-archlinux
held its PowerPC images back for weeks because of it. GHCR does not refuse
GitHub's own runners. This repository copies each repository's database,
packages and signatures to `ghcr.io/pkgforge-dev/mirror-archlinux/<arch>/<repo>`,
checks every copy with pacman itself before it is published, and ships
`client/pacman-oci`, the pacman `XferCommand` that reads it back.

| mirrored | from | state |
| --- | --- | --- |
| `x86_64/core` | Arch Linux | every three hours |

## Using it

```bash
curl -fsSL -o /usr/local/bin/pacman-oci https://raw.githubusercontent.com/pkgforge-dev/mirror-archlinux/main/client/pacman-oci
chmod 0755 /usr/local/bin/pacman-oci
```

`/etc/pacman.conf`:

```ini
[options]
XferCommand = /usr/local/bin/pacman-oci %o %u

[core]
Server = oci://ghcr.io/pkgforge-dev/mirror-archlinux/$arch/$repo
Include = /etc/pacman.d/mirrorlist
```

The `oci://` Server is read from the registry. Every other URL is handed to
curl, so the ordinary mirrors after it stay the fallback: when the registry
does not have a file, pacman moves on to the next Server, as it does for any
mirror.

⚠ Pin by digest before you use the mirror for a build anyone must reproduce, so
it cannot move under you:

```ini
Server = oci://ghcr.io/pkgforge-dev/mirror-archlinux/$arch/$repo@sha256:<db manifest digest>
```

| Server form | gives |
| --- | --- |
| `oci://.../$arch/$repo` | `latest`, which follows upstream |
| `oci://.../$arch/$repo:2026.10.13` | the first snapshot promoted that UTC day; it never moves once it exists |
| `oci://.../$arch/$repo@sha256:HEX` | exactly one snapshot. ⭐ The only real pin: the wrapper hashes the manifest it is given and refuses one that is not HEX |

Tags are labels; `@sha256:` is the pin. The digest a tag names now:

```bash
curl -sI -H 'Authorization: Bearer QQ==' -H 'Accept: application/vnd.oci.image.manifest.v1+json' \
  https://ghcr.io/v2/pkgforge-dev/mirror-archlinux/x86_64/core/manifests/latest | grep -i docker-content-digest
```

### What it costs

Measured with pacman 7.1.0:

- With an `XferCommand`, pacman downloads one file at a time; `ParallelDownloads`
  is ignored.
- pacman waits 2 s after every failed attempt. Arch publishes no
  `<repo>.db.sig`, so each repository costs about 2 s on every `-Sy` and every
  `-Fy`, from the mirror and from an ordinary mirror alike, and each file that
  falls through to the next Server costs 2 s more.
- During a GHCR outage, each manifest request gives up within about 45 s (15 s
  a try, no new try after 30 s), and a file then falls through to the next
  Server.
- `latest` can move between pacman's request for `<repo>.db` and its request for
  `<repo>.db.sig`. The wrapper pairs a database signature with the very database
  pacman just took (by its content), so this needs a snapshot that disappears
  between the two requests; a consumer that needs the pair atomic pins the
  digest.

⚠ With `DownloadUser` set, keep at least one sandbox feature enabled: with
`DownloadUser` and every `DisableSandbox*` option set together, pacman downloads
into root-owned directories while still running the `XferCommand` as the
download user, and every download fails.

### What the wrapper checks

Everything it reads is checked before pacman sees it, and pacman then checks
what it always checks.

1. A manifest asked for by digest must hash to that digest.
2. Exactly one layer must carry the name pacman asked for.
3. The blob's size and sha256 must equal that layer's descriptor.
4. pacman checks the file's sha256 against the database and its signature
   against the distribution's keyring.

A package's signature is always in the same manifest as the package: pacman
asks for a `.sig` from the server that served the file and from no other, so a
missing signature would end the install rather than fall through.

The wrapper is one POSIX sh file. It needs curl, awk, sed, sha256sum and
mktemp, and the test suite runs it under bash with gawk, dash with mawk, and
busybox.

## How the mirror works

```
plan ──> mirror (shards) ──> stage ──> verify (batches) ──> promote ──> report
```

1. **plan** reads the database from the distribution's own servers only, and
   refuses one that is malformed, or behind the promoted database or another
   candidate (some package built before the same package in the other). Files
   the promoted database already names with the same sha256 cost nothing; the
   rest are split into shards.
2. **mirror** downloads each file from any listed server, checks its size and
   sha256 against the database, and pushes it with its signature under its own
   tag. ⛔ A tag is written once: a tag already holding other bytes is never
   overwritten, and holds the target.
3. **stage** pushes the database under a staging tag once every new file is on
   the registry, and checks that it reads with no credential.
4. **verify** runs pacman in the target's own Arch image, with the wrapper as its
   `XferCommand` and the staged digest as its only Server, and downloads every
   new file: pacman checks every sha256 and signature as a consumer would.
5. **promote** tags the staged digest: the day's tag (once), the content tags,
   then `latest`, never backwards, and reads it back through the wrapper.
6. **report** writes the run's summary, and keeps one issue per problem that
   does not heal by itself: a package that is private, or a tag that would
   have to change. `watchdog.yml` raises one when a target stops following
   upstream.

Targets are independent. One that is held never holds another, and a held
target keeps serving its last promoted snapshot.

The design, every decision in it and the measurements behind them:
[`HISTORY/design.md`](HISTORY/design.md).

## Adding a target

A file `targets/<arch>-<repo>.conf`, where `<arch>` is pacman's `$arch`:

```ini
arch = aarch64
repo = core
# The distribution's own servers: the database comes only from these.
db_server = https://example.org/$arch/$repo
# More servers package bytes may come from. Every byte is checked against the
# database before it is pushed, so any mirror will do.
server = https://mirror.example.org/$arch/$repo
# tag: base
verify_image = docker.io/library/archlinux:base@sha256:<digest>
verify_platform = linux/amd64
keyring = archlinux-keyring
```

The first push creates the GHCR package. If it comes out private, the run says
so and opens an issue with the settings link: GitHub has no API for package
visibility, so making it public is one click.

## Tests

```bash
scripts/install-test-tools ./bin
PATH="$PWD/bin:$PATH" tests/run.sh all
```

`static` lints and checks policy, `unit` needs no network, and `integration`
runs the whole mirror against a local registry with docker or podman. Every
test has been seen to fail: [`HISTORY/tests-seen-to-fail.md`](HISTORY/tests-seen-to-fail.md).

## Trust

Push access to this repository is the mirror's trust root: any workflow on any
branch can ask for `packages: write`. Every workflow starts from
`permissions: {}`, only `main` promotes, and actions are pinned by commit, which
the repository requires. ⚠ Renovate, when it is enabled for the repository,
pushes its own branches, so it is trusted with that root too; its pull requests
wait for a person, and no other bot is given push access.
