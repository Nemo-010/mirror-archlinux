<!-- written by scripts/status-collect on 2026-10-31T13:54:06Z -->
The Worker fails its probe in 214 run(s) in a row, since 2026-10-15T09:27:18Z. worker-down opens at 2 runs in a row over 50 minutes or more.

Worker: https://ghcr.mirror.archlinux.pkgforge.dev. Each probe is a GET with no redirect followed. A target with `latest` must answer 302 to https://*.githubusercontent.com. A target with no `latest` must answer 404.

| target | probe | HTTP | expected | seconds | result |
| --- | --- | --- | --- | --- | --- |
| aarch64-alarm | db | 302 | 302 | 0.537382 | ok |
| aarch64-alarm | package | 302 | 302 | 0.221887 | ok |
| aarch64-aur | db | 302 | 302 | 0.304515 | ok |
| aarch64-aur | package | 302 | 302 | 0.261485 | ok |
| aarch64-core | db | 302 | 302 | 0.220580 | ok |
| aarch64-core | package | 302 | 302 | 0.148722 | ok |
| aarch64-extra | db | 302 | 302 | 0.222241 | ok |
| aarch64-extra | package | 302 | 302 | 0.143147 | ok |
| armv7h-alarm | db | 302 | 302 | 0.239195 | ok |
| armv7h-alarm | package | 302 | 302 | 0.150230 | ok |
| armv7h-aur | db | 302 | 302 | 0.447341 | ok |
| armv7h-aur | package | 302 | 302 | 0.258412 | ok |
| armv7h-core | db | 302 | 302 | 0.234432 | ok |
| armv7h-core | package | 302 | 302 | 0.247112 | ok |
| armv7h-extra | db | 302 | 302 | 0.472108 | ok |
| armv7h-extra | package | 302 | 302 | 0.227571 | ok |
| loong64-core | db | 302 | 302 | 0.395758 | ok |
| loong64-core | package | 302 | 302 | 0.150633 | ok |
| loong64-extra | db | 302 | 302 | 0.230131 | ok |
| loong64-extra | package | 302 | 302 | 0.167537 | ok |
| powerpc-base | db | 302 | 404 | 0.225761 | HTTP 302, expected 404 |
| powerpc-base-any | db | 302 | 404 | 0.209107 | HTTP 302, expected 404 |
| powerpc64-base | db | 302 | 404 | 0.208029 | HTTP 302, expected 404 |
| powerpc64-base-any | db | 302 | 404 | 0.329321 | HTTP 302, expected 404 |
| powerpc64le-base | db | 302 | 404 | 0.206780 | HTTP 302, expected 404 |
| powerpc64le-base-any | db | 302 | 404 | 0.329170 | HTTP 302, expected 404 |
| riscv64-core | db | 302 | 302 | 0.220140 | ok |
| riscv64-core | package | 302 | 302 | 0.150221 | ok |
| riscv64-extra | db | 302 | 302 | 0.228356 | ok |
| riscv64-extra | package | 302 | 302 | 0.152106 | ok |
| x86_64-core | db | 302 | 302 | 0.249792 | ok |
| x86_64-core | package | 302 | 302 | 0.315479 | ok |
| x86_64-extra | db | 302 | 302 | 0.209020 | ok |
| x86_64-extra | package | 302 | 302 | 0.151267 | ok |
| x86_64-multilib | db | 302 | 302 | 0.221856 | ok |
| x86_64-multilib | package | 302 | 302 | 0.136989 | ok |

reproduce:

```bash
curl --connect-timeout 10 --max-time 30 -sS -o /dev/null -w "%{http_code} %{redirect_url}\n" "https://ghcr.mirror.archlinux.pkgforge.dev/powerpc/base/base.db"
```

This issue closes itself when the Worker passes its probes again.
