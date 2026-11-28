<!-- written by scripts/status-collect on 2026-11-28T11:58:52Z -->
The Worker fails its probe in 510 run(s) in a row, since 2026-10-15T09:27:18Z. worker-down opens at 2 runs in a row over 50 minutes or more.

Worker: https://ghcr.mirror.archlinux.pkgforge.dev. Each probe is a GET with no redirect followed. A target with `latest` must answer 302 to https://*.githubusercontent.com. A target with no `latest` must answer 404.

| target | probe | HTTP | expected | seconds | result |
| --- | --- | --- | --- | --- | --- |
| aarch64-alarm | db | 302 | 302 | 0.465378 | ok |
| aarch64-alarm | package | 302 | 302 | 0.300679 | ok |
| aarch64-aur | db | 302 | 302 | 0.433205 | ok |
| aarch64-aur | package | 302 | 302 | 0.404698 | ok |
| aarch64-core | db | 302 | 302 | 0.410087 | ok |
| aarch64-core | package | 302 | 302 | 0.350961 | ok |
| aarch64-extra | db | 302 | 302 | 0.309416 | ok |
| aarch64-extra | package | 302 | 302 | 0.314916 | ok |
| armv7h-alarm | db | 302 | 302 | 0.301856 | ok |
| armv7h-alarm | package | 302 | 302 | 0.345072 | ok |
| armv7h-aur | db | 302 | 302 | 0.349013 | ok |
| armv7h-aur | package | 302 | 302 | 0.306611 | ok |
| armv7h-core | db | 302 | 302 | 0.387211 | ok |
| armv7h-core | package | 302 | 302 | 0.326907 | ok |
| armv7h-extra | db | 302 | 302 | 0.301947 | ok |
| armv7h-extra | package | 302 | 302 | 0.277516 | ok |
| loong64-core | db | 302 | 302 | 0.291104 | ok |
| loong64-core | package | 302 | 302 | 0.286225 | ok |
| loong64-extra | db | 302 | 302 | 0.267864 | ok |
| loong64-extra | package | 302 | 302 | 0.298302 | ok |
| powerpc-base | db | 302 | 404 | 0.315640 | HTTP 302, expected 404 |
| powerpc-base-any | db | 302 | 404 | 0.294191 | HTTP 302, expected 404 |
| powerpc64-base | db | 302 | 404 | 0.380645 | HTTP 302, expected 404 |
| powerpc64-base-any | db | 302 | 404 | 0.277314 | HTTP 302, expected 404 |
| powerpc64le-base | db | 302 | 404 | 0.344884 | HTTP 302, expected 404 |
| powerpc64le-base-any | db | 302 | 404 | 0.270830 | HTTP 302, expected 404 |
| riscv64-core | db | 302 | 302 | 0.304050 | ok |
| riscv64-core | package | 302 | 302 | 0.284276 | ok |
| riscv64-extra | db | 302 | 302 | 0.344525 | ok |
| riscv64-extra | package | 302 | 302 | 0.308850 | ok |
| x86_64-core | db | 302 | 302 | 0.313163 | ok |
| x86_64-core | package | 302 | 302 | 0.303466 | ok |
| x86_64-extra | db | 302 | 302 | 0.286618 | ok |
| x86_64-extra | package | 302 | 302 | 0.273003 | ok |
| x86_64-multilib | db | 302 | 302 | 0.288983 | ok |
| x86_64-multilib | package | 302 | 302 | 0.273247 | ok |

reproduce:

```bash
curl --connect-timeout 10 --max-time 30 -sS -o /dev/null -w "%{http_code} %{redirect_url}\n" "https://ghcr.mirror.archlinux.pkgforge.dev/powerpc/base/base.db"
```

This issue closes itself when the Worker passes its probes again.
