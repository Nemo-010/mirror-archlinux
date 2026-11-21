<!-- written by scripts/status-collect on 2026-11-21T11:03:03Z -->
The Worker fails its probe in 441 run(s) in a row, since 2026-10-15T09:27:18Z. worker-down opens at 2 runs in a row over 50 minutes or more.

Worker: https://ghcr.mirror.archlinux.pkgforge.dev. Each probe is a GET with no redirect followed. A target with `latest` must answer 302 to https://*.githubusercontent.com. A target with no `latest` must answer 404.

| target | probe | HTTP | expected | seconds | result |
| --- | --- | --- | --- | --- | --- |
| aarch64-alarm | db | 302 | 302 | 0.417240 | ok |
| aarch64-alarm | package | 302 | 302 | 0.308007 | ok |
| aarch64-aur | db | 302 | 302 | 0.345867 | ok |
| aarch64-aur | package | 302 | 302 | 0.403713 | ok |
| aarch64-core | db | 302 | 302 | 0.371384 | ok |
| aarch64-core | package | 302 | 302 | 0.368589 | ok |
| aarch64-extra | db | 302 | 302 | 0.306156 | ok |
| aarch64-extra | package | 302 | 302 | 0.296032 | ok |
| armv7h-alarm | db | 302 | 302 | 0.309872 | ok |
| armv7h-alarm | package | 302 | 302 | 0.302628 | ok |
| armv7h-aur | db | 302 | 302 | 0.379462 | ok |
| armv7h-aur | package | 302 | 302 | 0.300865 | ok |
| armv7h-core | db | 302 | 302 | 0.300705 | ok |
| armv7h-core | package | 302 | 302 | 0.302193 | ok |
| armv7h-extra | db | 302 | 302 | 0.319155 | ok |
| armv7h-extra | package | 302 | 302 | 0.312831 | ok |
| loong64-core | db | 302 | 302 | 0.301233 | ok |
| loong64-core | package | 302 | 302 | 0.310745 | ok |
| loong64-extra | db | 302 | 302 | 0.319276 | ok |
| loong64-extra | package | 302 | 302 | 0.313083 | ok |
| powerpc-base | db | 302 | 404 | 0.303763 | HTTP 302, expected 404 |
| powerpc-base-any | db | 302 | 404 | 0.317190 | HTTP 302, expected 404 |
| powerpc64-base | db | 302 | 404 | 0.310358 | HTTP 302, expected 404 |
| powerpc64-base-any | db | 302 | 404 | 0.328711 | HTTP 302, expected 404 |
| powerpc64le-base | db | 302 | 404 | 0.303613 | HTTP 302, expected 404 |
| powerpc64le-base-any | db | 302 | 404 | 0.327341 | HTTP 302, expected 404 |
| riscv64-core | db | 302 | 302 | 0.295201 | ok |
| riscv64-core | package | 302 | 302 | 0.315218 | ok |
| riscv64-extra | db | 302 | 302 | 0.324895 | ok |
| riscv64-extra | package | 302 | 302 | 0.313384 | ok |
| x86_64-core | db | 302 | 302 | 0.315782 | ok |
| x86_64-core | package | 302 | 302 | 0.324892 | ok |
| x86_64-extra | db | 302 | 302 | 0.294277 | ok |
| x86_64-extra | package | 302 | 302 | 0.305616 | ok |
| x86_64-multilib | db | 302 | 302 | 0.304678 | ok |
| x86_64-multilib | package | 302 | 302 | 0.345864 | ok |

reproduce:

```bash
curl --connect-timeout 10 --max-time 30 -sS -o /dev/null -w "%{http_code} %{redirect_url}\n" "https://ghcr.mirror.archlinux.pkgforge.dev/powerpc/base/base.db"
```

This issue closes itself when the Worker passes its probes again.
