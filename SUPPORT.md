# Support

## Where to report a problem

| Problem | Destination |
| --- | --- |
| Suspected vulnerability or exposed secret | [Private security reporting](https://github.com/lpm-dev/lpm-vault/security/advisories/new) |
| App crash, incorrect behavior, or documentation error | [Vault bug report](https://github.com/lpm-dev/lpm-vault/issues/new?template=bug_report.yml) |
| Installation, Gatekeeper, or update problem | [Installation and update report](https://github.com/lpm-dev/lpm-vault/issues/new?template=installation_update.yml) |
| App and CLI values or approval disagree | [CLI integration report](https://github.com/lpm-dev/lpm-vault/issues/new?template=cli_integration.yml) |
| Proposed app workflow | [Feature request](https://github.com/lpm-dev/lpm-vault/issues/new?template=feature_request.yml) |
| CLI behavior without the app | [LPM CLI issues](https://github.com/lpm-dev/rust-client/issues) |
| LPM.dev login or cloud sync from Vault | [Vault bug report](https://github.com/lpm-dev/lpm-vault/issues/new?template=bug_report.yml) |

Usage instructions are in the [app guide](https://cli.lpm.dev/docs/dev/lpm-vault) and [env guide](https://cli.lpm.dev/docs/dev/env).
Search existing issues before you create a report.
Maintainers triage hosted-service reports from the app.

## Before you share evidence

Use dummy values in a minimal reproduction.
Remove secrets, tokens, account details, private paths, project identifiers, and private URLs from logs and screenshots.
Do not attach a real `.env` file, Keychain export, signing key, or provisioning profile.
If evidence includes a live credential, rotate it before you share the report.

Include the app version and build number from **About LPM Vault**.
Include the macOS version, CPU architecture, and installation method.
For CLI integration, include the output of `lpm --version`.

## Installation and updates

LPM Vault requires macOS 14 or later on Apple silicon or Intel.
Download the official app from [vault.lpm.dev/download](https://vault.lpm.dev/download).
Move it into **Applications** before use.

If macOS rejects the app, record the exact message and report it through the installation form.
Do not disable Gatekeeper, remove quarantine attributes, or bypass signature checks.

Use **Check for Updates…** in the application menu.
Background update checks require your consent.
If an update fails, download the current official installer and report the error.
Do not delete Keychain data as an update workaround.

## Unlock and Keychain access

Touch ID is optional. Your Mac login password provides another unlock method.
Unlock the Mac session before you retry a failed Keychain operation.

The official app and CLI need valid signatures for their shared Keychain group.
Unsigned and ad-hoc source builds do not gain access by copying the official entitlements.
If a source build cannot access shared records, use the official app and CLI.

If access still fails, report the exact error with dummy data.
Do not reset your Keychain or delete credentials to create a reproduction.

## CLI values and approval

Use **Connect CLI** for the intended env project and directory.
Run the script from that directory with the official signed CLI.
Use the [env guide](https://cli.lpm.dev/docs/dev/env) to select the intended environment.

If the CLI asks for authentication, inspect the project's **CLI approval** setting.
If you cancel authentication, the CLI stops before it runs the script.
The app's **Lock** button does not enable CLI approval.
Neither control revokes values that a process already received.

For a report, show masked output or dummy values.
Do not use commands that print real secrets as diagnostic evidence.

## Cloud sync and member keys

Select the intended account, organization, and env project before a sync operation.
Verify that the account has access to that project.
If authentication expired, sign in again through the app.

If a sync conflict appears, compare the available recovery actions before you replace remote data.
Keep any necessary local copy secure.
If you cannot identify the correct copy, report the conflict with dummy data before a destructive action.

If a member key changes unexpectedly, ask the member or organization administrator to verify the fingerprint.
Do not approve an unfamiliar key to bypass a sync error.

## Clipboard and exports

Another application can read or retain copied values.
An exported `.env` file contains plaintext secrets.
Locking the app does not erase an exported file or another application's copy.
Protect exported files and keep them out of source control.

See [PRIVACY.md](PRIVACY.md) and [SECURITY.md](SECURITY.md) for the documented boundaries.
