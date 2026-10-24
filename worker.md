<!-- written by scripts/status-collect on 2026-10-24T12:14:01Z -->
The Worker fails its probe in 128 run(s) in a row, since 2026-10-15T09:27:18Z. worker-down opens at 2 runs in a row over 50 minutes or more.

Worker: https://ghcr.mirror.archlinux.pkgforge.dev. Each probe is a GET with no redirect followed. A target with `latest` must answer 302 to https://*.githubusercontent.com. A target with no `latest` must answer 404.

| target | probe | HTTP | expected | seconds | result |
| --- | --- | --- | --- | --- | --- |
| aarch64-alarm | db | 302 | 302 | 0.434720 | ok |
| aarch64-alarm | package | 302 | 302 | 0.274574 | ok |
| aarch64-aur | db | 302 | 302 | 0.346887 | ok |
| aarch64-aur | package | 302 | 302 | 0.373330 | ok |
| aarch64-core | db | 302 | 302 | 0.395867 | ok |
| aarch64-core | package | 302 | 302 | 0.265061 | ok |
| aarch64-extra | db | 302 | 302 | 0.383565 | ok |
| aarch64-extra | package | 302 | 302 | 0.394393 | ok |
| armv7h-alarm | db | 302 | 302 | 0.271234 | ok |
| armv7h-alarm | package | 302 | 302 | 0.286028 | ok |
| armv7h-aur | db | 302 | 302 | 0.261217 | ok |
| armv7h-aur | package | 302 | 302 | 0.285746 | ok |
| armv7h-core | db | 302 | 302 | 0.259481 | ok |
| armv7h-core | package | 302 | 302 | 0.261865 | ok |
| armv7h-extra | db | 302 | 302 | 0.254468 | ok |
| armv7h-extra | package | 302 | 302 | 0.306543 | ok |
| loong64-core | db | 302 | 302 | 0.248905 | ok |
| loong64-core | package | 302 | 302 | 0.299103 | ok |
| loong64-extra | db | 302 | 302 | 0.260924 | ok |
| loong64-extra | package | 302 | 302 | 0.293372 | ok |
| powerpc-base | db | 302 | 404 | 0.287861 | HTTP 302, expected 404 |
| powerpc-base-any | db | 302 | 404 | 0.320067 | HTTP 302, expected 404 |
| powerpc64-base | db | 302 | 404 | 0.255983 | HTTP 302, expected 404 |
| powerpc64-base-any | db | 302 | 404 | 0.258315 | HTTP 302, expected 404 |
| powerpc64le-base | db | 302 | 404 | 0.286936 | HTTP 302, expected 404 |
| powerpc64le-base-any | db | 302 | 404 | 0.315157 | HTTP 302, expected 404 |
| riscv64-core | db | 302 | 302 | 0.426768 | ok |
| riscv64-core | package | 302 | 302 | 0.296261 | ok |
| riscv64-extra | db | 302 | 302 | 0.278092 | ok |
| riscv64-extra | package | 302 | 302 | 0.277851 | ok |
| x86_64-core | db | 302 | 302 | 0.263549 | ok |
| x86_64-core | package | 302 | 302 | 0.276029 | ok |
| x86_64-extra | db | 302 | 302 | 0.253279 | ok |
| x86_64-extra | package | 302 | 302 | 0.278144 | ok |
| x86_64-multilib | db | 302 | 302 | 0.285173 | ok |
| x86_64-multilib | package | 302 | 302 | 0.296999 | ok |

reproduce:

```bash
curl --connect-timeout 10 --max-time 30 -sS -o /dev/null -w "%{http_code} %{redirect_url}\n" "https://ghcr.mirror.archlinux.pkgforge.dev/powerpc/base/base.db"
```

This issue closes itself when the Worker passes its probes again.
