# Signed update and shared credential findings

The primary agent verified both credential findings before changing the implementations. No subagents participated.

| ID | Source | Category | Location | Claim and evidence | Disposition | Coverage | Commit | PR status |
| --- | --- | --- | --- | --- | --- | --- | --- | --- |
| AUTH-SWIFT | Primary agent | Security | `AuthCredentialBackend.swift`, extracted from `AuthSessionCoordinator.swift` | The auth query omitted the access group and Data Protection selection. The query regression failed before the change. | Verified | Query scope, migration failure/recovery, signed Rust-to-Swift-to-Rust test | `b427b51` | [Vault #24](https://github.com/lpm-dev/lpm-vault/pull/24) |
| AUTH-RUST | Primary agent | Security | CLI `lpm-auth` macOS credential queries | The native auth query omitted the same access boundary. The query regression failed before the change. | Verified | Native query scope, six migration tests, signed cross-language test | CLI `c98b86eb` | [CLI #736](https://github.com/lpm-dev/rust-client/pull/736) |
| CI-TOOLCHAIN | Primary agent | Correctness | `VaultWorkspaceView.swift`, `AppDelegateTests.swift` | Xcode 26.2 rejected the large body expression and newer image-attachment API in CI runs 35018096807 and 35019004357. Separate view expressions and PNG data attachments support the pinned toolchain. | Verified | Full Swift test and universal build jobs on the pinned compiler | `04e9320` and the test compatibility commit | [Vault #24](https://github.com/lpm-dev/lpm-vault/pull/24) |

Totals: three directly identified findings, three verified and fixed, zero rejected, zero externally blocked findings, zero pending findings. Subagent findings received: zero.

The documentation companion is [docs #226](https://github.com/lpm-dev/rust-client-docs/pull/226).

## Release validation

- Vault: 620 tests across 30 suites, with warnings treated as errors.
- Universal release bundle: clean build, expected update metadata, valid Developer ID signatures for Vault and all Sparkle components.
- Release tooling: 40 shell checks and five Python tests.
- Website: container build and four HTTP test groups, including malformed routes and cache headers.
- Sparkle: real DMG and feed signatures verified. A modified feed failed verification.
- Keychain: signed Rust and Swift test bundles exchanged a synthetic credential in both directions and deleted their test items.

## External rollout dependencies

These dependencies concern publication, rather than unresolved code findings:

- The Vault GitHub secrets need the Developer ID export password and Apple issuer UUID.
- Anonymous GitHub downloads need a public repository and a published release.
- A full installed-app update test needs two notarized release artifacts and the public feed.

The release workflow fails before publication when required signing inputs or public-release configuration are absent. The release procedure tracks these dependencies in `LPMVault/RELEASING.md`.
