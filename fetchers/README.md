# fetchers

Read one URL through the client that can read it, with a fallback order and a
structural check of the body. `plan` and `mirror` read upstream; this directory
is what they use when a plain `curl` does not get an answer.

## The manager

```
fetchers/fetcher.sh [OPTIONS] URL OUT
```

It tries the clients in order and stops at the first body that passes the
check. Exit status: 0 the body is in `OUT`, 4 the server says the URL is
absent (404 or 410), 1 no client read it or the body failed its check.

| option | meaning |
| --- | --- |
| `--client LIST` | clients to try, in order (comma or space separated) |
| `--expect KIND` | `any` (default), `db`, `tar` or `sig` |
| `--retries N` | attempts per client (default 2) |
| `--timeout SEC` | whole-call deadline of one attempt (default 300) |
| `--connect SEC` | connect deadline (default 20) |
| `--no-cache` | do not read or write the per-host preference |
| `--list` | print the clients that can run here, one per line |
| `--quiet` | no per-attempt line on stderr |

Environment: `FETCHER_CLIENTS` (the order), `FETCHER_CACHE` (the cache root,
`~/.cache/mirror-archlinux/fetcher` by default), `FETCHER_SUMMARY` (a TSV log of
every attempt), `FETCHER_QUIET` (`1` for quiet).

The order is `curl curl-impersonate chromium cloak-browser playwright`. curl is
first, so a host that answers curl costs one curl call. The client that read a
host last is kept in `FETCHER_CACHE/hosts/<host>` and is tried first the next
time, so a host that needs a browser pays for the browser once.

A 403 body is not a body: the client that got it is not an answer, and the next
client is tried. A 404 or 410 ends the call with status 4, because another
client would hear the same.

## The clients

| client | what it is | install |
| --- | --- | --- |
| `curl` | the system curl, used first | system |
| `curl-impersonate` | [lexiforest/curl-impersonate](https://github.com/lexiforest/curl-impersonate), a maintained curl that sends one browser's TLS and HTTP/2 profile | `fetchers/curl-impersonate/install.sh` |
| `chromium` | the playwright package and its full Chrome-for-Testing build; the request is an in-page `fetch()`, so it uses Chromium's own network stack and cookies | `fetchers/chromium/install.sh` |
| `cloak-browser` | [CloakHQ/CloakBrowser](https://github.com/CloakHQ/CloakBrowser), a Chromium build with its client profile set in the engine | `fetchers/cloak-browser/install.sh` |
| `playwright` | [feder-cr/invisible_playwright](https://github.com/feder-cr/invisible_playwright) | `fetchers/playwright/install.sh` |

`fetchers/install.sh [CLIENT...]` runs the installers. With no argument it
installs every client. The installers write into this tree, and
`fetchers/.gitignore` keeps their build products out of the repository.

A client is available when its `available` script exits 0. `available` for
`chromium`, `cloak-browser` and `playwright` also checks that node, the
package and the browser build are present, so `--list` reflects the host.

## Drift

```
fetchers/drift.sh [--json | --env] [--key NAME] [--ttl SECONDS] [--force]
```

Every version comes from the release the tool's own project publishes at the
time it is read; nothing is pinned by hand. Values are kept in
`FETCHER_CACHE/drift.json` for 24 h. A lookup that fails keeps the cached
value rather than moving backwards. The keys are `curl-impersonate`,
`cloak-browser`, `invisible-playwright` and `playwright`; the installers read
the tag they need from here.

## Use in a workflow

`scripts/lib.sh` reads every upstream URL through `fetch_upstream`. Set
`MIRROR_FETCHER` to `fetchers/fetcher.sh` and every read goes through the
manager instead of curl, with no other change:

```yaml
- run: |
    fetchers/install.sh curl-impersonate
    export MIRROR_FETCHER="$PWD/fetchers/fetcher.sh"
    scripts/plan "$RUNNER_TEMP/plan"
```

`fetchers/install.sh chromium` also installs the browser, which is what a
runner needs when the origin answers curl with an interstitial 403.

## Measured

- 2026-10-15, residential network: `curl` reads `base.db` of all three
  ArchPOWER arches and of `base-any` with one call each, and passes the `db`
  check. The three `.db.sig` files pass the `sig` check.
- 2026-08-28 and 2026-09-18, GitHub runner: the same URLs answer 403 with
  a Cloudflare interstitial. The browser clients exist for that case.
- The unit tests (`tests/unit/80-fetchers.sh`) run the manager against a curl
  stand-in and a faked curl-impersonate, so client selection, the fallback
  order, the structural checks and the version resolver are covered without a
  network or a browser. A browser client itself is not started by the tests.
