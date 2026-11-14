<!-- written by scripts/status-collect on 2026-11-14T18:05:14Z -->
The Worker fails its probe in 369 run(s) in a row, since 2026-10-15T09:27:18Z. worker-down opens at 2 runs in a row over 50 minutes or more.

Worker: https://ghcr.mirror.archlinux.pkgforge.dev. Each probe is a GET with no redirect followed. A target with `latest` must answer 302 to https://*.githubusercontent.com. A target with no `latest` must answer 404.

| target | probe | HTTP | expected | seconds | result |
| --- | --- | --- | --- | --- | --- |
| aarch64-alarm | db | 302 | 302 | 0.504746 | ok |
| aarch64-alarm | package | 302 | 302 | 0.368784 | ok |
| aarch64-aur | db | 302 | 302 | 0.342830 | ok |
| aarch64-aur | package | 302 | 302 | 0.481933 | ok |
| aarch64-core | db | 302 | 302 | 0.310332 | ok |
| aarch64-core | package | 302 | 302 | 0.321995 | ok |
| aarch64-extra | db | 302 | 302 | 0.322219 | ok |
| aarch64-extra | package | 302 | 302 | 0.409936 | ok |
| armv7h-alarm | db | 302 | 302 | 0.317676 | ok |
| armv7h-alarm | package | 302 | 302 | 0.296427 | ok |
| armv7h-aur | db | 302 | 302 | 0.303333 | ok |
| armv7h-aur | package | 302 | 302 | 0.301937 | ok |
| armv7h-core | db | 302 | 302 | 0.375151 | ok |
| armv7h-core | package | 302 | 302 | 0.282317 | ok |
| armv7h-extra | db | 302 | 302 | 0.321430 | ok |
| armv7h-extra | package | 302 | 302 | 0.376580 | ok |
| loong64-core | db | 302 | 302 | 0.290178 | ok |
| loong64-core | package | 302 | 302 | 0.336027 | ok |
| loong64-extra | db | 302 | 302 | 0.327271 | ok |
| loong64-extra | package | 302 | 302 | 0.298308 | ok |
| powerpc-base | db | 302 | 404 | 0.301358 | HTTP 302, expected 404 |
| powerpc-base-any | db | 302 | 404 | 0.288520 | HTTP 302, expected 404 |
| powerpc64-base | db | 302 | 404 | 0.349499 | HTTP 302, expected 404 |
| powerpc64-base-any | db | 302 | 404 | 0.301262 | HTTP 302, expected 404 |
| powerpc64le-base | db | 302 | 404 | 0.332364 | HTTP 302, expected 404 |
| powerpc64le-base-any | db | 302 | 404 | 0.372693 | HTTP 302, expected 404 |
| riscv64-core | db | 302 | 302 | 0.398595 | ok |
| riscv64-core | package | 302 | 302 | 0.354776 | ok |
| riscv64-extra | db | 302 | 302 | 0.291829 | ok |
| riscv64-extra | package | 302 | 302 | 0.314568 | ok |
| x86_64-core | db | 302 | 302 | 0.293159 | ok |
| x86_64-core | package | 302 | 302 | 0.279011 | ok |
| x86_64-extra | db | 302 | 302 | 0.308408 | ok |
| x86_64-extra | package | 302 | 302 | 0.347842 | ok |
| x86_64-multilib | db | 302 | 302 | 0.315411 | ok |
| x86_64-multilib | package | 302 | 302 | 0.321357 | ok |

reproduce:

```bash
curl --connect-timeout 10 --max-time 30 -sS -o /dev/null -w "%{http_code} %{redirect_url}\n" "https://ghcr.mirror.archlinux.pkgforge.dev/powerpc/base/base.db"
```

This issue closes itself when the Worker passes its probes again.
