<!-- written by scripts/status-collect on 2026-10-17T21:45:28Z -->
The Worker fails its probe in 37 run(s) in a row, since 2026-10-15T09:27:18Z. worker-down opens at 2 runs in a row over 50 minutes or more.

Worker: https://ghcr.mirror.archlinux.pkgforge.dev. Each probe is a GET with no redirect followed. A target with `latest` must answer 302 to https://*.githubusercontent.com. A target with no `latest` must answer 404.

| target | probe | HTTP | expected | seconds | result |
| --- | --- | --- | --- | --- | --- |
| aarch64-alarm | db | 302 | 302 | 0.478420 | ok |
| aarch64-alarm | package | 302 | 302 | 0.361671 | ok |
| aarch64-aur | db | 302 | 302 | 0.289258 | ok |
| aarch64-aur | package | 302 | 302 | 0.269568 | ok |
| aarch64-core | db | 302 | 302 | 0.328034 | ok |
| aarch64-core | package | 302 | 302 | 0.287762 | ok |
| aarch64-extra | db | 302 | 302 | 0.293258 | ok |
| aarch64-extra | package | 302 | 302 | 0.282484 | ok |
| armv7h-alarm | db | 302 | 302 | 0.280947 | ok |
| armv7h-alarm | package | 302 | 302 | 0.260743 | ok |
| armv7h-aur | db | 302 | 302 | 0.265287 | ok |
| armv7h-aur | package | 302 | 302 | 0.306805 | ok |
| armv7h-core | db | 302 | 302 | 0.380212 | ok |
| armv7h-core | package | 302 | 302 | 0.270139 | ok |
| armv7h-extra | db | 302 | 302 | 0.285847 | ok |
| armv7h-extra | package | 302 | 302 | 0.268612 | ok |
| loong64-core | db | 302 | 302 | 0.307477 | ok |
| loong64-core | package | 302 | 302 | 0.190459 | ok |
| loong64-extra | db | 302 | 302 | 0.282503 | ok |
| loong64-extra | package | 302 | 302 | 0.269652 | ok |
| powerpc-base | db | 302 | 404 | 0.271467 | HTTP 302, expected 404 |
| powerpc-base-any | db | 302 | 404 | 0.301946 | HTTP 302, expected 404 |
| powerpc64-base | db | 302 | 404 | 0.253675 | HTTP 302, expected 404 |
| powerpc64-base-any | db | 302 | 404 | 0.290926 | HTTP 302, expected 404 |
| powerpc64le-base | db | 302 | 404 | 0.261281 | HTTP 302, expected 404 |
| powerpc64le-base-any | db | 302 | 404 | 0.349192 | HTTP 302, expected 404 |
| riscv64-core | db | 302 | 302 | 0.267481 | ok |
| riscv64-core | package | 302 | 302 | 0.162808 | ok |
| riscv64-extra | db | 302 | 302 | 0.262711 | ok |
| riscv64-extra | package | 302 | 302 | 0.301620 | ok |
| x86_64-core | db | 302 | 302 | 0.212416 | ok |
| x86_64-core | package | 302 | 302 | 0.350375 | ok |
| x86_64-extra | db | 302 | 302 | 0.165205 | ok |
| x86_64-extra | package | 302 | 302 | 0.170714 | ok |
| x86_64-multilib | db | 302 | 302 | 0.281008 | ok |
| x86_64-multilib | package | 302 | 302 | 0.332555 | ok |

reproduce:

```bash
curl --connect-timeout 10 --max-time 30 -sS -o /dev/null -w "%{http_code} %{redirect_url}\n" "https://ghcr.mirror.archlinux.pkgforge.dev/powerpc/base/base.db"
```

This issue closes itself when the Worker passes its probes again.
