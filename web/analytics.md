# Website analytics and search setup

The landing page uses the shared LPM PostHog project, 127102, in EU Cloud.
Only the website sends analytics. The Mac app sends no analytics.

## Privacy

PostHog uses `cookieless_mode: "always"` and memory persistence.
The SDK creates no analytics cookies or persistent browser identity.
Cookieless identities represent visitor-days, not permanent visitors.
Events retain the SDK's `$raw_user_agent` value during delivery because PostHog needs this value for its daily identity hash.
PostHog removes the raw user agent and connection IP before it stores cookieless events.
The website does not collect or send an IP property.
Person profiles, replay, automatic capture, exceptions, performance capture, and remote feature configuration are disabled.
The website respects Global Privacy Control and Do Not Track.
The footer offers an opt-out button.
Only the explicit opt-out preference persists in local storage, under `vault_website_analytics_optout`.
Opt-out changes stop capture in other open tabs.

Event properties retain the first landing source and medium.
They omit query strings, fragments, credentials, and private referrer paths.
The SDK sends only approved website events and a limited property list.
It does not read app secrets or `.env` files.
Campaign source and medium accept bounded tokens. Other campaign data is discarded.
Verification visits use `utm_source=codex-seo-verification` and `is_test_traffic: true`.
Customer reports and intent actions exclude these visits.
Verification clicks keep the test source on links to CLI documentation.

## Events

| Event | Meaning |
| --- | --- |
| `$pageview` | Landing-page view. |
| `vault_download_clicked` | Download intent. This does not prove download completion or installation. |
| `vault_docs_clicked` | Product documentation or security-model intent. |
| `vault_github_clicked` | Repository or changelog intent. |

All events use `app: "vault"`, `attribution_version: 2`, and `analytics_mode: "cookieless"`.
Clicks include approved destination and page-section labels, not raw destination URLs.
Local previews do not send analytics.

## SDK and serving rules

The website serves PostHog JS 1.435.7 from its own origin.
The source is the official npm package, `posthog-js@1.435.7`, file `dist/module.slim.no-external.js`.
`npm run build:sdk --prefix web` creates the browser bundle with pinned esbuild 0.28.2.
CI rebuilds the bundle and rejects a changed output. The route test also verifies its SHA-256 digest.
The slim build excludes optional extension classes. The loader runs only after the hostname and privacy checks pass.
At most 20 early intent events wait in memory for the SDK. Opt-out and load failures discard this queue.
The original package license is in `public/vendor/LICENSE-PostHog.txt`.
The versioned SDK is immutable. Custom analytics code revalidates.
The page includes a content hash in the analytics script URL to prevent stale code after deployment.
The content security policy permits same-origin code and connections only.
Remote SDK extensions, scripts, and feature configuration are disabled.

## Event delivery

The SDK sends events to `/ingest/e/` on the website origin.
Nginx forwards this endpoint to `https://eu.i.posthog.com/e/` and verifies the upstream TLS certificate.
The proxy accepts POST bodies of at most 64 KiB. It rejects foreign browser origins and exposes no other PostHog endpoints.
The proxy removes cookies, authorization, and referrer headers. It discards upstream cookies and cache headers.
The proxy retains the forwarding chain for cookieless ingestion. Deployment proxies must preserve the visitor address in that chain.
The proxy uses the container DNS resolvers and refreshes upstream addresses every five minutes.
`VAULT_DNS_RESOLVERS` can override those resolvers.
Pageviews use fetch delivery with SDK retries. Navigation clicks use sendBeacon.
Same-origin delivery avoids blocks against PostHog domains. Blockers can still reject website paths.
Browser privacy signals and the explicit opt-out always stop capture.

## Verification

The Teamfox PostHog activity view initially excluded internal and test users.
The existing live site delivered marked verification pageviews. Those events appeared after the filter was disabled for that view.
The project reports retain their existing test filters.

1. Open Activity in EU project 127102.
2. Disable “Filter out internal and test users” in the temporary verification view.
3. Visit `https://vault.lpm.dev/?utm_source=codex-seo-verification&utm_medium=test`.
4. Verify that the pageview has `app: vault`, `is_test_traffic: true`, and the canonical current URL.
5. Verify a documentation or GitHub intent event.
6. Restore the filter for customer analysis.

Automated browser tests block every third-party domain and use the real local SDK with a mock ingestion response.
The TLS proxy fixture verifies delivery restrictions and header removal without external event traffic.
An explicit live verification can use `VAULT_VERIFY_LIVE_POSTHOG=1` with `node --test web/tests/test_delivery.cjs`.
That command sends two marked test events through the local production proxy to EU PostHog.

## Search

The canonical landing page is `https://vault.lpm.dev/`.
The sitemap contains only that page. Downloads, update feeds, and release artifacts are excluded.
`robots.txt` advertises the sitemap.
Google and Bing properties use the Vault hostname to keep reporting separate from other LPM sites.
Accepted crawl requests do not establish indexing or ranking recovery.
