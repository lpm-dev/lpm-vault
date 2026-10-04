# Vault PostHog delivery audit

The primary agent inspected the live site, the real SDK, and the authenticated Teamfox PostHog activity view.
No subagents participated. The code commit is `eafc34c`. The PR targets `main` independently of the Lighthouse PR.
Both branches include the same browser-test infrastructure commit. Neither feature requires the other feature's code.

## Finding ledger

| ID | Category | Location | Claim and evidence | Disposition | Coverage | Commit | PR status |
| --- | --- | --- | --- | --- | --- | --- | --- |
| PH-1 | Correctness | `public/analytics.js`, `nginx.conf` | Blocking PostHog domains dropped the original image's pageview. The trace showed a rejected POST to EU PostHog. | Verified | Real SDK browser test with all third-party domains blocked, TLS proxy fixture, live ingestion | `eafc34c` | Ready for review |
| PH-2 | Performance | SDK bundle, page scripts | The 363 KB bundle transferred 126 KB with gzip. Lighthouse reported approximately 92 KiB unused. It loaded for opted-out visits. | Verified | Reproducible slim build, size/digest gate, eligible-load tests, bounded early intent queue | `eafc34c` | Ready for review |
| PH-3 | Correctness | SDK source-map directive | Chrome attempted an absent source map and reported CSP errors. The new production bundle has no source-map directive. | Verified | Served bundle route test | `eafc34c` | Ready for review |
| PH-4 | Correctness | SDK loading and privacy choice | A privacy change during asynchronous SDK loading left the choice enabled. A new regression failed before correction. | Verified | Privacy transition, opt-out race, failed load, and bounded queue tests | `eafc34c` | Ready for review |
| PH-5 | Correctness | PostHog activity view | The live integration appeared inactive. Existing marked visits appeared after the view included internal and test users. | Rejected | Authenticated activity view showed cookieless Vault pageviews. The new proxy also delivered a pageview and GitHub intent. | Not applicable | Documented |

Totals: 5 received, 4 verified and fixed, 1 rejected with evidence, 0 externally blocked, 0 pending.
The Lighthouse unused-JavaScript diagnostic maps to PH-2.

## Delivery and privacy evidence

The browser test uses the actual pinned SDK and production page in a temporary browser context.
It blocks every third-party domain. The original Docker image fails because its pageview targets `eu.i.posthog.com`.
The modified image sends the pageview and GitHub intent to the website origin.
The test verifies cookieless fields, absent persistent identity, sanitized queries, and manual opt-out.
The test models a normal visitor because PostHog deliberately drops automated browsers with `navigator.webdriver` enabled.

The isolated TLS fixture verifies allowed methods, origins, body size, fixed upstream routing, and header removal.
It also verifies that an untrusted upstream certificate produces HTTP 502.
Normal CI tests send no real PostHog events.
An explicit live run sent two marked events through the local production proxy to EU project 127102.
The authenticated Teamfox activity view showed both events.

The proxy preserves the visitor forwarding chain for cookieless ingestion.
The deployment's existing proxies must retain the visitor address. The application does not treat this address as authentication.
Same-origin delivery avoids domain-based blockers. It retains DNT, GPC, and manual opt-out behavior.

## Validation and performance

All 19 JavaScript/browser tests, 14 Docker route tests, and 3 TLS proxy tests passed.
The 714 Swift tests, 40 shell release tests, and 21 Python release tests passed.
The warning-as-error release build and nested signature checks passed.
The pinned SDK rebuild produced the same SHA-256 digest.

The original bundle contains 362,709 bytes. The slim bundle contains 164,110 bytes, a 55% reduction.
Gzip level 1 matches Nginx's default compression level.
The same compression method produced 125,925 bytes before and 62,172 bytes after, a 51% reduction.
These are asset-size measurements. They do not imply a fixed improvement in network-dependent Lighthouse scores.
