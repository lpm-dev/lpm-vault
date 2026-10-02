# Privacy

## Mac app

The Mac app sends no analytics or session recordings.
Local secrets use the Data Protection Keychain on this Mac and do not sync through iCloud Keychain.

The app makes network requests for features that you use:

- Login and account operations contact LPM.dev.
- Optional cloud sync sends encrypted values and the metadata needed for project and account operations.
- Account images can require image requests.
- Update checks contact the public Sparkle feed and release download service.

Encryption of secret values does not hide all project, account, or request metadata from the service.
Hosting providers receive network connection information for requests they serve.

Sparkle asks before it enables background update checks.
Automatic downloads start disabled.
The app disables Sparkle system-profile reporting.
Use **Check for Updates…** for a manual check.

Copied values and exported `.env` files leave the app's storage boundary.
The app cannot remove values that another process already received or retained.

## Product website

[vault.lpm.dev](https://vault.lpm.dev) uses PostHog EU Cloud for limited website analytics.
The website counts pageviews and clicks on download, documentation, and GitHub links.
A download click does not prove installation.

Analytics use cookieless mode and memory persistence.
The website creates no analytics cookies or persistent browser identity.
PostHog derives daily identities from connection information and removes raw IP and user-agent data before event storage.

Session recordings, automatic capture, person profiles, exception capture, performance capture, and remote feature configuration are disabled.
The website limits event properties and omits query strings, fragments, credentials, and private referrer paths.
It does not read app secrets or `.env` files.

The website respects Global Privacy Control and Do Not Track.
The footer provides **Turn off website analytics**.
Only the explicit opt-out preference persists in browser local storage.

Read [web/analytics.md](web/analytics.md) for the event list and implementation details.

## Reports

Do not send credentials or private project data in public reports.
Use [SECURITY.md](SECURITY.md) for suspected disclosure or other vulnerabilities.
Use [SUPPORT.md](SUPPORT.md) for ordinary problems and questions.
