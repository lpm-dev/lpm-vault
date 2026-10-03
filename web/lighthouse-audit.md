# Vault Lighthouse audit

The supplied Lighthouse report paths were absent from the workspace.
Fresh audits used Lighthouse 13.5.1 against the live site and local Docker images.
The live mobile scores were 96 performance, 96 accessibility, 100 best practices, and 92 SEO.
The live desktop scores were 100 performance, 100 accessibility, 100 best practices, and 92 SEO.

## Finding ledger

All findings came from the primary agent. No subagents participated.
The code commit is `868b1bf`. The PR targets `main`.

| ID | Category | Location | Claim and evidence | Disposition | Coverage | Commit | PR status |
| --- | --- | --- | --- | --- | --- | --- | --- |
| LH-1 | Correctness | `public/style.css`, matrix header | Mobile text contrast was 2.68:1. The browser regression failed before the fix. | Verified | Axe contrast at 390px and 1440px | `868b1bf` | Ready for review |
| LH-2 | Correctness | `nginx.conf`, CSP | Same-origin metadata fetches failed under CSP. Lighthouse rejected valid `robots.txt`. | Verified | Browser fetch and route policy tests | `868b1bf` | Ready for review |
| LH-3 | Performance | `Dockerfile`, `nginx.conf` | Lighthouse reported approximately 11 KiB of avoidable repeat transfers for CSS and scripts. | Verified | Served asset digests, immutable headers, missing hash, unversioned revalidation | `868b1bf` | Ready for review |
| LH-4 | Correctness | `public/llms.txt` | The optional agent metadata file was absent. The new route test failed before its addition. | Verified | Public product metadata route test | `868b1bf` | Ready for review |

Totals: 4 received, 4 verified and fixed, 0 rejected, 0 externally blocked, 0 pending.
The unused PostHog bundle belongs to the separate analytics-delivery concept.

## Validation

Browser tests cover the real page and CSP. Route tests build the production Docker image.
All 15 JavaScript tests and 16 route tests passed.
The 714 Swift tests, 40 shell release tests, and 21 Python release tests passed.
The release build and nested signature checks passed with warnings treated as errors.

Three cold mobile samples alternated the original and modified Docker images on the same host.
Both images scored 99 performance and 100 best practices.
Accessibility increased from 96 to 100. SEO increased from 92 to 100.
Median simulated LCP stayed approximately 2.25 seconds. This change does not claim a cold-load speed increase.
Content-based asset names improve repeat visits and preserve freshness after deployment.

The small stylesheet remains render-blocking to prevent an unstyled first paint.
Lighthouse's dependency-tree diagnostic identifies that stylesheet and recommends no additional preconnect origins.
The live site's network latency differs from local Docker latency. Local scores do not predict a fixed production performance score.
