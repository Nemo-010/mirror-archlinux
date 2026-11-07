<!-- written by scripts/status-collect on 2026-11-07T19:37:51Z -->
The Worker fails its probe in 294 run(s) in a row, since 2026-10-15T09:27:18Z. worker-down opens at 2 runs in a row over 50 minutes or more.

Worker: https://ghcr.mirror.archlinux.pkgforge.dev. Each probe is a GET with no redirect followed. A target with `latest` must answer 302 to https://*.githubusercontent.com. A target with no `latest` must answer 404.

| target | probe | HTTP | expected | seconds | result |
| --- | --- | --- | --- | --- | --- |
| aarch64-alarm | db | 302 | 302 | 0.340677 | ok |
| aarch64-alarm | package | 302 | 302 | 0.350644 | ok |
| aarch64-aur | db | 302 | 302 | 0.211769 | ok |
| aarch64-aur | package | 302 | 302 | 0.263381 | ok |
| aarch64-core | db | 302 | 302 | 0.273563 | ok |
| aarch64-core | package | 302 | 302 | 0.213878 | ok |
| aarch64-extra | db | 302 | 302 | 0.318376 | ok |
| aarch64-extra | package | 302 | 302 | 0.234592 | ok |
| armv7h-alarm | db | 302 | 302 | 0.263229 | ok |
| armv7h-alarm | package | 302 | 302 | 0.214801 | ok |
| armv7h-aur | db | 302 | 302 | 0.238896 | ok |
| armv7h-aur | package | 302 | 302 | 0.211149 | ok |
| armv7h-core | db | 302 | 302 | 0.232897 | ok |
| armv7h-core | package | 302 | 302 | 0.214153 | ok |
| armv7h-extra | db | 302 | 302 | 0.287101 | ok |
| armv7h-extra | package | 302 | 302 | 0.267522 | ok |
| loong64-core | db | 302 | 302 | 0.231276 | ok |
| loong64-core | package | 302 | 302 | 0.306460 | ok |
| loong64-extra | db | 302 | 302 | 0.254387 | ok |
| loong64-extra | package | 302 | 302 | 0.224711 | ok |
| powerpc-base | db | 302 | 404 | 0.257998 | HTTP 302, expected 404 |
| powerpc-base-any | db | 302 | 404 | 0.238301 | HTTP 302, expected 404 |
| powerpc64-base | db | 302 | 404 | 0.210393 | HTTP 302, expected 404 |
| powerpc64-base-any | db | 302 | 404 | 0.216336 | HTTP 302, expected 404 |
| powerpc64le-base | db | 302 | 404 | 0.242518 | HTTP 302, expected 404 |
| powerpc64le-base-any | db | 302 | 404 | 0.250712 | HTTP 302, expected 404 |
| riscv64-core | db | 302 | 302 | 0.366670 | ok |
| riscv64-core | package | 302 | 302 | 0.200121 | ok |
| riscv64-extra | db | 302 | 302 | 0.300555 | ok |
| riscv64-extra | package | 302 | 302 | 0.218941 | ok |
| x86_64-core | db | 302 | 302 | 0.194236 | ok |
| x86_64-core | package | 302 | 302 | 0.170602 | ok |
| x86_64-extra | db | 302 | 302 | 0.246469 | ok |
| x86_64-extra | package | 302 | 302 | 0.212618 | ok |
| x86_64-multilib | db | 302 | 302 | 0.230314 | ok |
| x86_64-multilib | package | 302 | 302 | 0.231370 | ok |

reproduce:

```bash
curl --connect-timeout 10 --max-time 30 -sS -o /dev/null -w "%{http_code} %{redirect_url}\n" "https://ghcr.mirror.archlinux.pkgforge.dev/powerpc/base/base.db"
```

This issue closes itself when the Worker passes its probes again.
