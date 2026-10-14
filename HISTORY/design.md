# Design

Arch Linux repositories on GHCR as OCI artifacts, read by pacman through an
`XferCommand`. Written 2026-10-13, when the mirror was built; every number in
it was measured that day unless it says otherwise.

## Why

GitHub's runners are refused by upstream mirrors more and more. ArchPOWER, the
only publisher of the PowerPC ports, answers every datacentre address with a
Cloudflare challenge (HTTP 403), measured from runners on 2026-08-28 and
2026-09-18. docker-archlinux held its ppc images back from 2026-09-18 for it
(its `HISTORY/outage-2026-09.md`). A self-run mirror on a rented server was the
alternative, and was set aside for cost. GHCR serves GitHub's own runners, and
public packages cost nothing to store.

## Decisions by the maintainer (2026-10-13)

1. One GHCR repository per arch and repo:
   `ghcr.io/pkgforge-dev/mirror-archlinux/<arch>/<repo>`, `<arch>` being
   pacman's `$arch`.
2. Each package file is one tag, its escaped filename; its signature is a
   second layer of the same manifest. The database is tag `latest`, plus a
   dated tag per UTC day.
3. Consumers: `XferCommand = /usr/local/bin/pacman-oci %o %u` and
   `Server = oci://ghcr.io/pkgforge-dev/mirror-archlinux/$arch/$repo`, with the
   upstream Servers after it as the fallback.
4. Keep everything; nothing is ever deleted.
5. Runners are debloated when the work needs the room, and the work runs in
   parallel as far as it usefully goes.
6. Phase 1 mirrors x86_64 core only, sharded anyway, and changes nothing in
   docker-archlinux. ppc ingest is a later phase.
7. The repository's Actions settings were hardened on 2026-10-13: the default
   token is read-only, Actions cannot approve pull requests, and only actions
   pinned by commit may run.

## Measurements that shaped it

| what | measured |
| --- | --- |
| GHCR, `Authorization: Bearer QQ==` | 200 on a public manifest and blob; no header 401; an unrecognised bearer 403 with no challenge |
| GHCR blob GET | 307 to a signed URL on `pkg-containers.githubusercontent.com`; curl does not carry the Authorization header across hosts, and the URL needs none; ranges work |
| GHCR blobs | scoped per repository: another repository's blob answers 404 |
| GHCR tags | resolved without regard to case: `latest`, `LATEST` and `Latest` name one manifest |
| GHCR, a 129 character reference | 303 to an HTML page on github.com |
| GHCR limits (docs) | 10 GB per layer, a 10 minute upload |
| GHCR visibility | no REST endpoint changes it (the packages API offers GET, DELETE and restore only) |
| pacman 7.1.0 `XferCommand` | fork and execvp, no shell; `%o` and `%u` replaced only as whole words; exec failure is 127, like any failed download |
| pacman, after a failure | sleeps 2 s, tries the next Server; never deletes the `.part` |
| pacman, downloads | one at a time under an `XferCommand` |
| pacman, a package's `.sig` | asked only of the server that served the package; when the signature is required, a failed `.sig` ends the transaction |
| pacman, with `DownloadUser` | the `XferCommand` runs as that user (uid switch and NO_NEW_PRIVS only), from `<syncdir or cachedir>/download-XXXXXX/` |
| pacman, signatures | checked against the database's `%PGPSIG%` when present, else the detached `.sig`; `-Sw` checks both sha256 and signatures |
| pacman 7.1, a package with `%PGPSIG%` | still asks the `XferCommand` for its `.sig` and stores it in the cache, unread (2026-10-14) |
| `%PGPSIG%` coverage | Arch x86_64 core and extra 100%; aarch64, armv7h 100%; loong64 core 263/295; riscv64 core 9/294; ArchPOWER base-powerpc64le 0/3735, base-any 262/2200 |
| `%PGPSIG%` against `.sig` | base64 decoded, byte identical (zlib) |
| filenames | about 44000 across nine databases, all `[A-Za-z0-9@._+:-]`, longest 92; `:` in 761, `+` in 246; a few dozen with upper case |
| newest `%BUILDDATE%` | not monotonic: archived core of 2026-10-02 and 10-03 differ and share it, so do 10-10 and 10-11 |
| per package `%BUILDDATE%` | over all eleven consecutive daily pairs 10-01 to 10-12, the newer database never had an older package and the older always had one when the bytes differed |
| superseded files | gone from every Arch mirror within a day, in `os/` and `pool/` alike |
| sizes | x86_64 core 299 packages, 1.85 GiB; extra 15041, 107.6 GiB, 10680 under 1 MiB, largest 3.29 GB |
| runners (docs and maintainers) | 4 vCPU; about 87 GB free on `/`, 14 GB guaranteed; `/mnt` not guaranteed |
| pkgforge-dev | GitHub Free: 20 concurrent jobs shared by every repository of the organisation |

## Storage layout

```
ghcr.io/pkgforge-dev/mirror-archlinux/x86_64/core
  :<escaped filename>     one package: the file, and its signature
  :staging                the candidate database of the run on main
  :staging-<branch>       the candidate of a run from another branch
  :latest                 the promoted database
  :YYYY.MM.DD             the first database promoted that UTC day; never moves
  :db-<sha256 of core.db>     the promoted database by content
  :files-<sha256 of core.files>
```

### Tags

A package tag is the filename with `+` as `_p`, `:` as `_c`, `@` as `_a`, and a
literal `_` as `_u` only when the next character is one of `p c a u`, so
`x86_64` stays `x86_64` and the mapping is injective. Tags are lower case
because GHCR folds case: a filename with upper case, or one the mapping cannot
carry within 128 characters, is stored under `fn-` and the hex sha256 of the
name. That form has no dot, and every escaped package name has `.pkg.tar`, so
the two never meet, and neither meets `latest`, `staging` or a date. The
mapping lives in `client/pacman-oci --tag` and nowhere else; the scripts call
it.

The judge of the design review asked for `_` as `__` (the draft's rule). The
rule above was kept instead: it is injective too, keeps the names readable as
the maintainer approved them, and is lower case throughout.

### Manifests

Package: artifact type `application/vnd.pkgforge.archlinux.package.v1`, layer 0
the package (`application/vnd.pkgforge.archlinux.pkg.v1`), layer 1 its
signature (`application/pgp-signature`), each titled with its filename.
Database: artifact type `application/vnd.pkgforge.archlinux.db.v1`, layers
`<repo>.db` and `<repo>.files` and any `.sig` upstream publishes beside them,
byte for byte, annotated with the upstream server, both sha256 values, the
package count, the newest build date and the ISO 8601 time it was fetched.

## The invariant

⛔ A database reaches `latest` only after every file it names is on the
registry and every file new since the promoted database has passed pacman's
own checks through the wrapper.

## Rules, and the failure each one prevents

- **The database comes from the distribution's own servers only.** Arch
  databases are unsigned, and whoever supplies the database chooses which
  validly signed packages are installed. Package bytes may come from any
  server; each is checked against the database.
- **Never behind.** A candidate is dropped when some package in it was built
  before the same package in the promoted database, or in another candidate.
  `allow_older` lifts the first comparison for a deliberate upstream downgrade.
  A candidate that differs from the promoted database only by packages added
  or dropped shows no build date either way, and may be an older copy from a
  server that lags: while a db_server still serves the promoted database, that
  one is kept, and the change is taken once every db_server agrees.
  Promote then refuses a staged snapshot fetched before the one `latest` names,
  so a re-run or a second writer cannot roll consumers back.
- **A package tag is written once.** A tag holding other bytes under a name is
  never overwritten: the promoted database or an older snapshot may name those
  bytes, and pacman refuses a file whose sha256 it does not expect, with no
  other Server tried. A run that meets one holds the target and opens
  `replaced-<target>` for a person. A signature missing beside the right package
  bytes is repaired by pushing again with the same blob.
- **A package never lacks its signature when the database has one.** The layer
  is the database's `%PGPSIG%`, decoded; with no `%PGPSIG%` the detached `.sig`
  is downloaded, and a file is pushed unsigned only when every server answers
  404 for it, as upstream ships it.
- **The `.sig` a consumer stores is the one pacman would check.** pacman checks
  against `%PGPSIG%` and stores the served `.sig` unread, so verify compares
  every stored `.sig` with the decoded `%PGPSIG%`; a mismatch fails the batch
  and names the file. Without it, a wrong layer would pass verify and break a
  later `pacman -U` from the cache.
- **Every field read from a database is checked first.** A filename with `/`, a
  space, a leading `-` or `.`, a control character or a byte above 0x7e is
  refused with the whole database. Names makepkg allows that the tag mapping
  cannot carry go to the `fn-` tag.
- **Absent means the registry said so.** Only 404 with `NAME_UNKNOWN` or
  `MANIFEST_UNKNOWN` is absent; anything else fails the target for that run.
- **A file upstream superseded during a run** holds the target for that run;
  the next run plans from the newer database. No archive server is consulted.
- **A file that never succeeds** holds its target until upstream drops or
  rebuilds it; the watchdog's `stale-<target>` issue is what surfaces it, and
  each run's summary names the file and its error.
- **No exit is silent.** Every script that sources `scripts/lib.sh` has an ERR
  trap that names the command which ended it under `set -e`. It found the
  first intermittent fault on its first run: `oras version | awk '... exit'`
  in `scripts/install-oras`, where awk closed the pipe while oras still wrote,
  the pipeline failed with SIGPIPE (141), and a promote ended with no message.
  No pipeline in a script ends in a reader that stops early
  (`tests/static/35-pipeline-traps.sh`).

## Jobs

`sync.yml`, every three hours and on dispatch:

| job | permissions | timeout | does |
| --- | --- | --- | --- |
| plan | contents, packages read | 15 | `scripts/plan`: candidates, floor, skip or todo, shards |
| mirror | contents, packages write | 120 | `scripts/mirror-shard` per shard: `mirror-file` over the lines, several at a time |
| stage | contents, packages write | 20 | `scripts/stage`: every new file accounted for, the database under staging, the anonymous read, verify batches |
| verify | contents | 90 | `scripts/verify-batch` per batch: pacman in the target's image |
| promote | contents, packages write | 15 | `scripts/promote` per staged target, on main only |
| report | contents, issues write | 10 | `scripts/report`: the summary, `visibility-` and `replaced-` issues |
| keepalive | actions write | 10 | `keep-schedules-enabled`, `check-schedules-fired` |

`max_parallel` (default 8) caps both matrices: the organisation's 20 concurrent
jobs are shared with every other repository, docker-archlinux's builds
included. Shards are at most 512 MiB and 400 files, verify batches 2 GiB and
400 files, both packed largest first onto the lightest.

`watchdog.yml`, daily: `scripts/check-staleness` for every target, through the
wrapper's token flow (`PACMAN_OCI_NO_DUMMY=1`), so that path runs against GHCR
on schedule too, and the two schedule checks. A target is stale when upstream's
database differs from the one `latest` serves and that snapshot was fetched
longer ago than the tolerance `scripts/cron-tolerance` derives from sync.yml's
cron. That tolerance is in days: a three-hourly cron gets three days. ⚠ That is
coarse, and accepted: it is a measured routine reused, and a mirror that stops
is still seen within the week.

### Disk

The work goes to the largest writable filesystem among `$RUNNER_TEMP`, `/mnt`
and `/tmp`, counted once each. Each file is deleted once pushed, so a shard
needs room only for its `PARALLEL` largest files; `scripts/debloat-runner` runs
only when that does not fit, and `ci.yml` runs it on every push so it is seen to
work. If the room is still short, `PARALLEL` comes down.

## Running outside GitHub Actions

Every script reads only `MIRROR_REGISTRY`, `MIRROR_NAMESPACE`, `REGISTRY_USER`,
`REGISTRY_TOKEN`, `TARGETS_DIR` and its arguments, so a source runners cannot
read can be ingested from another host.

- Every GHCR repository is first created by `sync.yml` with the workflow token,
  which links it to this repository. A package first pushed from outside is not
  linked, and the workflow token can then never write to it.
- An outside host never uses a maintainer's token: GHCR accepts only classic
  tokens, which can write every package their owner can. It uses a dedicated
  account granted write on these packages alone.
- Every script logs in through `--password-stdin` into a registry
  configuration inside its own temporary directory, removed on exit.
- A push must keep above GHCR's 10 minute upload limit: the largest x86_64
  extra file needs 5.5 MB/s.

## The first runs (2026-10-13, branch wip)

| what | measured |
| --- | --- |
| first sync, x86_64 core | plan 25 s; 4 shards of 74 to 75 files each, 53 s to 3 min 10 s; stage 35 s; verify 6.5 min |
| pushes | 299 of 299 read back right on the first try: GHCR read-after-push was consistent |
| upstream spread | 75, 75, 75 and 74 files from the four servers: the per-shard rotation works |
| push rate | up to 34 MB/s for a single file |
| verify | pacman, as `alpm`, downloaded 1888 MiB through the wrapper from GHCR, then checked the keyring and every package's integrity |
| visibility | the package came out public: the pkgforge-dev organisation creates packages public |
| second sync, nothing new | every file `present`, nothing pushed; shards 12 to 17 s |
| consumer, residential network | stock Arch config, `DownloadUser = alpm`, the mirror as core's only Server: `pacman -Sy` 6.0 s (2 s of it pacman's pause after the absent `core.db.sig`), `pacman -S nano` 4.3 s |
| the token path | `PACMAN_OCI_NO_DUMMY=1` against GHCR: 401, anonymous token, 200 |
| debloat on a runner | 12 of 12 directories removed in 45 s, 85 GiB free to 120 GiB |
| first promotion, from `main` (2026-10-14) | run 38490975315: `latest`, `2026.10.14`, `db-` and `files-` name one snapshot of 299 packages; a consumer's synced `core.db` hashes to its `db-` tag; `-Sy` 4.0 s, `-S nano` 5.1 s |

## The code review

The implementation was reviewed on 2026-10-13 by four independent reviewers
(the wrapper, the pipeline, the workflows, the tests), each proving a defect in
a container rather than arguing it, and a judge ruled on 26 findings: 10
confirmed, 13 refuted because the fix had already landed, 3 not worth their
cost. Every confirmed one is fixed and tested, among them: a manifest far
larger than any real one could keep pacman waiting in the parser (now capped at
64 KiB, given up at once); a TMPDIR the download user cannot write broke every
download (now falls back to pacman's own directory); an outage cost up to 60 s
a request (now 15 s a try); a lagging server that only dropped a package could
move `latest` back (the rule above).

Running every fault again afterwards found one gap the reviewers had not: no
fixture database carried `%PGPSIG%`, because pacman 7's `repo-add` embeds
signatures only with `--include-sigs`, so the suite never drove the path every
real core package takes. The fixture embeds them now, and the suite asserts it.
Driving that path then showed verify passing a wrong signature layer, which
pacman stores without reading; verify now compares it
(`HISTORY/tests-seen-to-fail.md`, "What the faults found").

## The design review

The draft was reviewed on 2026-10-13 by five independent reviewers (pacman,
registry, CI, failure modes, security), each measuring rather than guessing,
and a judge ruled on all 50 findings: 3 accepted, 45 accepted with changes, 2
rejected. The rules above are the result. The two rejected: a separate runner
per platform (no non-amd64 target yet), and a consumer-side age warning in the
wrapper (an idle upstream would trip it; the watchdog measures staleness at the
source instead).

## Open, to be measured

- Whether GHCR read-after-push stays consistent at seed scale: 299 of 299 read
  back on the first try for core; count read-back retries in the mirror
  results for extra.
- GHCR request volume at seed scale (about 15k manifest reads and pushes for
  x86_64 extra), 429s, token requests.
- Wrapper latency per package against pacman's own downloader.
- Matrix queue time under the organisation's job limit, at `max_parallel` 8.
- Runner disk at shard start, and whether debloat ever runs in production.
- Docker Hub pulls of the verify image from runners.
- `DownloadUser` with every sandbox feature disabled, in a container, before
  the README's warning is taken as measured (it is read from source).
- The signed-database race, once a signed target exists.
