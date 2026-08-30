# End-to-end audit round 3 ledger

Concept branch: `codex/end-to-end-vault-audit-round-3`

Base commit: `bb956c4`

Implementation commit: `a931f01`

Concept pull request: [#18](https://github.com/lpm-dev/lpm-vault/pull/18)

This ledger covers the correctness, security, and performance audit after pull request #17. Three read-only subagents supplied 20 audit reports.

The requested Daybreak security model was unavailable. The security audit used the fallback subagent `security_audit_fallback`.

The primary agent reproduced each report before it changed production code. The primary agent also found three defects during implementation and review.

## Finding ledger

| ID | Source | Category | Location | Claim | Evidence | Disposition | Coverage | Commit | PR status |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| PRI-PERF-001 | primary_agent | Performance | `SharedKeychainStore.cutOverToProtectedOnly` | A completed cutover repeated full Keychain enumeration for each stable-key access. | The fail-first regression observed two enumerations, 202 protected reads, 200 legacy reads, and 100 legacy deletes. | Verified | `a completed cutover does not enumerate protected vault accounts again` | `a931f01` | Open in #18 |
| CORR-AUTH-001 | correctness_audit | Correctness | `VaultStore.login` and `VaultStore.logout` | A suspended login write can persist after logout and restore the session. | A gated writer left `stale-login-token` after logout. The mutation queue now orders session writes and clears. | Verified | `logout cannot be overtaken by a suspended login session write` | `a931f01` | Open in #18 |
| CORR-AUTH-002 | correctness_audit | Correctness | `AuthSessionCoordinator.clear` and `VaultStore.logout` | Metadata cleanup failure kept a visible identity after credential revocation. | Corrupt expiry metadata caused cleanup failure after both credentials were deleted. The store still showed the account. | Verified | `a revoked session clears the visible account even when expiry cleanup fails` | `a931f01` | Open in #18 |
| CORR-AUTH-003 | correctness_audit | Correctness | `VaultStore.logout` | Logout from an old environment can clear the identity of the new environment. | A gated production logout cleared a development identity after an environment switch. | Verified | `an old-environment logout cannot clear the new environment identity` | `a931f01` | Open in #18 |
| CORR-SYNC-001 | correctness_audit | Correctness | `SyncService.request` and personal push conflict handling | The client discarded live HTTP 409 conflicts before conflict resolution. | The real service path returned `failed` for the live conflict body. Strict conflict decoding now reaches `conflict`. | Verified | `live personal 409 conflict reaches the conflict-resolution state` | `a931f01` | Open in #18 |
| CORR-UI-001 | correctness_audit | Correctness | `VaultStore.preparePushConfirmation` | Push confirmation counted only the default environment. | A five-key, two-environment project displayed one key before the fix. | Verified | `push confirmation counts keys in every environment` | `a931f01` | Open in #18 |
| SEC-KEY-004 | security_audit_fallback | Security | Local unlock and `VaultCrypto.ensureProtectedOnlyCutover` | Local-only and organization-only use never started protected-only Keychain cutover. | Only personal stable-key access called the cutover. Local unlock now starts the common cutover path. | Verified | `local-only unlock attempts protected-only Keychain cutover` | `a931f01` | Open in #18 |
| SEC-KEY-005 | security_audit_fallback | Security | Stable wrapping-key file inspection and deletion | A hard link kept the plaintext key after the app reported file deletion. | A second link retained all 32 key bytes. Both inspections now require one link. | Verified | `wrapping-key file cutover deletes only the exact verified regular file` | `a931f01` | Open in #18 |
| SEC-SYNC-004 | security_audit_fallback | Security | `VaultCrypto.decryptStableSyncData` | Crypto v2 accepted token-wrapped payloads authored by the server. | A v2 payload used a token-derived key after stable-key unwrap failed. V2 now requires the stable key. | Verified | `Protocol v2 rejects token-wrapped personal payloads` | `a931f01` | Open in #18 |
| SEC-PROC-001 | security_audit_fallback | Security | `LPMCLICompatibility` | Cutover discovery ran ambient programs and did not bound output or descendants. | Temporary scripts proved ambient execution, output growth, inherited stdout, and surviving children. | Verified | CLI location, lazy evaluation, output, timeout, and descendant-lifetime regressions | `a931f01` | Open in #18 |
| SEC-CLIP-004 | security_audit_fallback | Security | Clipboard actions in vault views | Copied dotenv assignments kept shell expansion and newline injection active. | A copied `$(...)` value ran when sourced. Clipboard assignments now use `EnvFileCodec.format`. | Verified | `dotenv export and clipboard text remain literal when sourced` | `a931f01` | Open in #18 |
| SEC-CLIP-005 | security_audit_fallback | Security | `ClipboardManager.copy` | Secret clipboard entries lacked concealed and transient markers. | Pasteboard type inspection showed only ordinary text. Secret copies now publish both marker types. | Verified | `an immediate clear removes only a clipboard value owned by the vault` | `a931f01` | Open in #18 |
| SEC-AUTH-002 | security_audit_fallback | Security | `KeychainAuthCredentialBackend.write` | Device-bound session credentials used a backup-migratable accessibility class. | Adds and updates used `WhenUnlocked`. Both now use `WhenUnlockedThisDeviceOnly`. | Verified | `auth credentials are device-bound on add and update` | `a931f01` | Open in #18 |
| SEC-FS-002 | security_audit_fallback | Security | Auth state files, directories, and lock files | Auth paths followed links and accepted unsafe ownership, modes, links, and file types. | Symlink, FIFO, hard-link, exposed-mode, and substituted-directory fixtures reached unsafe targets before the fix. | Verified | Linked, exposed, FIFO, substituted-directory, and concurrent lock regressions | `a931f01` | Open in #18 |
| PERF-CUTOVER-001 | performance_audit | Performance | Protected-only cutover | This report duplicates `PRI-PERF-001`. Stable-key operations repeated full migration work after marker installation. | The primary call-count regression reproduced the report and supplied the canonical finding. | Verified, duplicate of `PRI-PERF-001` | `a completed cutover does not enumerate protected vault accounts again` | `a931f01` | Open in #18 |
| PERF-CLI-DISCOVERY-001 | performance_audit | Performance | `LPMCLICompatibility` | First crypto access eagerly ran every CLI candidate. | An incompatible first candidate still started later candidates before the fix. Evaluation now stops at the first failure. | Verified | `CLI compatibility stops after the first incompatible trusted candidate` | `a931f01` | Open in #18 |
| PERF-KEYCHAIN-MARKER-001 | performance_audit | Performance | `SharedKeychainStore.legacyCompatibilityActive` | One transaction reread the irreversible cutover marker for each primitive. | Call counts showed repeated marker reads. The store now caches only a valid protected-only state. | Verified | `protected-only state is cached after one durable marker read` | `a931f01` | Open in #18 |
| PERF-KEYCHAIN-INDEX-001 | performance_audit | Performance | Content-only persistence transactions | Add, import, and pull paths rewrote unchanged project indexes, including rollback paths. | Mock call counts showed index writes for content-only changes. These paths now use `updateEnvironments`. | Verified | Add-secret, local import, and pull call-count regressions | `a931f01` | Open in #18 |
| PERF-UNLOCK-MAIN-001 | performance_audit | Performance | Initial workspace snapshot derivation | Initial load derived all workspace snapshots on the main actor. | The 100-by-500 benchmark had a 293.438 ms median main-actor gap. The new median is 3.126 ms. | Verified | `initialWorkspaceDerivation` benchmark with a main-actor heartbeat | `a931f01` | Open in #18 |
| PERF-SCHEMA-RAM-001 | performance_audit | Performance | Schema load and sync request encoding | A 15 MiB schema created repeated JSON object graphs and buffers. | The A/B median fell from 93.318 ms to 41.113 ms. Peak RSS fell from 91,996,160 to 76,447,744 bytes. | Verified | `largeSchemaPush` A/B benchmark | `a931f01` | Open in #18 |
| PERF-SYNC-DIGEST-001 | performance_audit | Performance | `SyncService.payloadDigest` | Digest calculation copied the full payload into temporary `Data` buffers. | The direct A/B median peak RSS fell from 51,331,072 to 32,899,072 bytes. | Verified | `largePayloadDigest` A/B benchmark | `a931f01` | Open in #18 |
| PRI-CORR-002 | primary_agent | Correctness | `LPMJSONValue` number decoding | The first typed schema implementation rounded precise JSON numbers. | The fail-first test changed `1.234567890123456789` and a 38-digit integer. `Decimal` preserves both values. | Verified | `schema JSON keeps numeric precision during request encoding` | `a931f01` | Open in #18 |
| PRI-CORR-003 | primary_agent | Correctness | Secure lock-file creation | Concurrent secure directory creation can produce `ENOENT` while opening a lock file. | The full parallel suite reproduced the error. A link-safe retry and a 32-caller regression removed the race. | Verified | `device identity initialization is stable across concurrent coordinators` | `a931f01` | Open in #18 |

## Performance measurements

The benchmark used release optimization with the same `DEBUG` test flag. Each workload used three samples after a warm gate.

The execution order alternated between the baseline and current binaries. Both binaries used the same fixtures and sample counts.

| Workload | Baseline median | Current median | Result |
| --- | --- | --- | --- |
| 15 MiB schema push | 93.318 ms, 91,996,160-byte peak RSS | 41.113 ms, 76,447,744-byte peak RSS | Time decreased 55.9%. Peak RSS decreased 16.9%. |
| 9 MiB digest, 10 passes | 36.737 ms, 51,331,072-byte peak RSS | 36.438 ms, 32,899,072-byte peak RSS | Time stayed flat. Peak RSS decreased 35.9%. |
| 100 projects by 500 keys | 295.601 ms total, 293.438 ms main-actor gap | 293.108 ms total, 3.126 ms main-actor gap | Main-actor blocking decreased 98.9%. |

The preserved binaries are in `/tmp/lpm-vault-round3-bench.Jjhzkx`.

- Baseline SHA-256: `7faadf75a39dd3817f8e0427efe1c64c80b393f35850d92d41432c7a52439f82`
- Current SHA-256: `51ce710852fb5449b94c2598263d4d327dbe7d82e2e9a895a39dd839b30cce84`

## Final verification

- `swift test --parallel --package-path LPMVault`: 371 tests passed in 20 suites.
- The focused Thread Sanitizer run passed 4 tests in 3 suites.
- `swift build -c release --package-path LPMVault` passed.
- The unsigned Xcode Debug build passed.
- `bash Scripts/Tests/release-tooling-tests.sh` passed 40 tests.
- `git diff --check` passed.
- The repository does not contain `bench/scripts/run-install-readiness`, so that command was not available.

## Final totals

- Subagent reports received: 20.
- Subagent reports verified and fixed: 20.
- Subagent reports rejected: 0.
- Subagent reports externally blocked: 0.
- Subagent reports pending: 0.
- Primary findings verified and fixed: 3.
- Canonical findings verified and fixed: 22.
