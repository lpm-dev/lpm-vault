# Security policy

LPM Vault handles project secrets, authentication credentials, encrypted sync data, and application updates.
Imported files, network responses, and downloaded artifacts are untrusted input.

## Supported versions

Security fixes target the latest published LPM Vault release.
Earlier releases are unsupported unless a release announcement states otherwise.
Keep the official LPM CLI current for the shared Keychain contract.

If practical, reproduce a suspected vulnerability on the latest release.
Do not delay a private report if you cannot update.

## Report a vulnerability

Use [GitHub private vulnerability reporting](https://github.com/lpm-dev/lpm-vault/security/advisories/new).
Do not report a vulnerability in a public issue or discussion.

Include:

- The app version and build number.
- The macOS version, CPU architecture, and installation method.
- The CLI version, if the report concerns CLI integration.
- The affected security boundary and potential impact.
- Reproduction steps or a minimal proof of concept with dummy values.
- Any known mitigation.

Remove live credentials, secret values, private project data, and personal information.
If a credential was exposed, rotate it before you share evidence.

Allow time for private triage and coordinated remediation before you publish details.

## In scope

- Unauthorized reads or writes across the shared Keychain access boundary.
- Bypasses of app authentication, locking, CLI approval, or approval for sensitive actions.
- Secret or credential disclosure through logs, errors, files, clipboard behavior, or unintended requests.
- Flaws in encryption, encrypted sync, member-key approval, or project and account binding.
- Authentication or authorization flaws in app requests to LPM.dev.
- Unsafe `.env` imports or exports that cross a documented file-access boundary.
- Bypasses of TLS validation, update signatures, release integrity, or application identity checks.
- Remotely triggered resource exhaustion with materially asymmetric attacker cost.

## Security boundaries and limits

The official app and signed CLI share a narrow Data Protection Keychain group.
Copied source code or entitlements do not grant access to that group.
Apple verifies the signature and provisioning profile.

The app's **Lock** button hides values and clears its authentication context.
The per-project **CLI approval** setting controls authentication for CLI reads.
Locking the app does not change that setting.

Locking or changing approval cannot revoke values that a script or another process already received.
An exported `.env` file remains plaintext after the app locks.
Clipboard data can be read or retained by another application.

Optional sync encrypts values before upload.
Project and account metadata are not secret values and can remain visible to the service.
Organization sharing requires trust decisions about member keys.

The app does not protect secrets from a fully compromised operating system or an authorized process after disclosure.
This limit does not exclude flaws that bypass another documented boundary.

## Out of scope

- Expected access by an authorized script or recipient after the user explicitly shares values.
- Compromise of systems outside LPM-controlled surfaces, without a flaw in an LPM boundary.
- Social engineering without a technical vulnerability.
- Findings that affect only unsupported releases and do not apply to the latest release.

If scope is unclear, report privately and explain the boundary you believe is affected.

See [PRIVACY.md](PRIVACY.md) for network activity and [SUPPORT.md](SUPPORT.md) for ordinary troubleshooting.
