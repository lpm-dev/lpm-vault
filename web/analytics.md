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
The source is the official npm package, `posthog-js@1.435.7`, file `dist/array.no-external.js`.
The original package license is in `public/vendor/LICENSE-PostHog.txt`.
The route test checks the SDK's SHA-256 digest.
The versioned SDK is immutable. Custom analytics code revalidates.
The page includes a content hash in the analytics script URL to prevent stale code after deployment.
The content security policy permits same-origin code and connections to `https://eu.i.posthog.com` only.
Remote SDK extensions, scripts, and feature configuration are disabled.

## Search

The canonical landing page is `https://vault.lpm.dev/`.
The sitemap contains only that page. Downloads, update feeds, and release artifacts are excluded.
`robots.txt` advertises the sitemap.
Google and Bing properties use the Vault hostname to keep reporting separate from other LPM sites.
Accepted crawl requests do not establish indexing or ranking recovery.
