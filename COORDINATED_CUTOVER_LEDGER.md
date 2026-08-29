# Coordinated vault cutover ledger

Concept branch: `codex/coordinated-vault-cutover`

App implementation commit: `1d5a06a`

Server implementation commit: `5d35fa9a`

Concept pull requests:

- App: [lpm-dev/lpm-vault#17](https://github.com/lpm-dev/lpm-vault/pull/17)
- Server: [tolgaergin/a-package-manager#155](https://github.com/tolgaergin/a-package-manager/pull/155)

This addendum resolves the four findings that were externally blocked at the end of the round 2 audit. The Rust client repository remained read-only. Its current 0.76 compatibility contract already supplies protocol-v2 AEAD context, Data Protection Keychain access, the persistent cutover marker, and the credential-authority file used by the app.

| ID | Source | Category | Location | Claim | Evidence | Disposition | Coverage | Commit | PR status |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| COR-007B / SEC-SYNC-001B | correctness_audit and security_audit | Correctness and security | App `VaultCrypto` and `SyncService`; server personal and organization sync routes | Protocol v1 did not authenticate vault identity or scope, and a signed response was not bound to one request. | Cross-language analysis reproduced the missing AEAD context. Protocol v2 now binds scope, canonical organization slug, vault ID, and crypto version. The authenticated response envelope binds a random request nonce, response identity, server version, and a length-prefixed payload digest. Server migration 0168 makes v2 the default and preserves bounded legacy reads until 2026-11-30. | Verified | Cross-language personal and organization AAD vectors; substitution, replay, downgrade, missing-binding, signed-envelope, route, and migration tests | App `1d5a06a`; server `5d35fa9a` | Included in [#17](https://github.com/lpm-dev/lpm-vault/pull/17) and [server #155](https://github.com/tolgaergin/a-package-manager/pull/155) |
| SEC-KEY-002 | security_audit | Security | App `VaultCrypto` legacy wrapping-key cutover | A readable filesystem copy of the stable wrapping key remained after migration to protected storage. | The app now requires every discovered CLI to satisfy the shared-Keychain version contract. It reopens the containing directory without following links, opens and verifies the exact owner-only regular file, checks device and inode identity immediately before `unlinkat`, and syncs the directory after deletion. Unsafe, changed, or divergent files are preserved with an error. | Verified | Exact verified deletion; symlink preservation; wrong-key preservation; unsafe-file inspection; CLI version-gate tests | App `1d5a06a` | Included in [#17](https://github.com/lpm-dev/lpm-vault/pull/17) |
| SEC-KEY-003 | security_audit | Security and correctness | App `SharedKeychainStore` compatibility authority | Legacy Keychain data remained authoritative indefinitely, while an uncoordinated authority change could hide a valid CLI update. | The coordinated cutover enumerates both stores, rejects divergent copies, reconciles and verifies every account, deletes only verified legacy copies, and commits the protected-only marker last. Deletion or marker failures restore removed legacy copies. After the marker, reads and writes use only the Data Protection Keychain. | Verified | Successful cutover ordering; divergence rejection; deletion rollback; marker rollback; protected-only read, write, add, and batching tests | App `1d5a06a` | Included in [#17](https://github.com/lpm-dev/lpm-vault/pull/17) |
| PERF-AUTH-001B | performance_audit and security_audit | Performance and security | App cross-process sync authorization | Every suspension boundary reacquired the credential lock and reparsed complete shared auth state. | One full authorization capture now returns the token and a validated authority-file generation. Later checks use one bounded `lstat` metadata comparison and fail closed on missing, corrupt, replaced, rotated, or logged-out state. The call-count regression records one full authorization capture for a sync. | Verified | Authorization amortization; corrupt and replaced authority state; peer rotation and logout; focused TSAN race coverage | App `1d5a06a` | Included in [#17](https://github.com/lpm-dev/lpm-vault/pull/17) |
| PRI-CUTOVER-001 | primary_agent | Correctness and security | App `LPMCLICompatibility` irreversible cutover gate | One compatible CLI installation could mask another discovered incompatible or unreadable installation and permit destructive cutover. | The failing regression covered mixed compatible and incompatible versions. The gate now requires a non-empty candidate set and requires every discovered executable to report a stable compatible version. | Verified | `protected-only cutover requires a shared-Keychain-compatible CLI` | App `1d5a06a` | Included in [#17](https://github.com/lpm-dev/lpm-vault/pull/17) |

## Verification

- App: 351 tests passed across 19 suites.
- App: 13 focused envelope, authorization-generation, and Keychain cutover tests passed under Thread Sanitizer.
- App: arm64 Xcode Debug build passed with code signing disabled.
- Server: 6,753 tests passed across 691 files; 46 focused contract and migration tests passed after final formatting.
- Server: lint, `db:push`, and migration audit passed. Pending migrations, unacknowledged historical gaps, and physical schema issues were all zero.
- Server: migration DDL passed two rollback-only applications, and the development database reports `vault_sync.crypto_version DEFAULT 2 NOT NULL`.
- Supabase security and performance advisors reported no error-level findings.
- Install readiness passed for the dogfood fixture in cold, warm, and up-to-date modes against the existing read-only Rust CLI binary.
- Cross-language payload digest: `129f6d5175b7c0875d84918c4cbf6a12a4843cea2167345b932568c94fb0dc8f`.

## Final totals

- Subagent findings received from the blocked set: 4.
- Primary-agent findings added during re-review: 1.
- Canonical ledger items: 5.
- Verified and fixed: 5.
- Rejected with evidence: 0.
- Externally blocked: 0.
- Pending: 0.

No blocked or pending finding remains in this app/server concept.
