# Nightly release review ledger

Concept: automated Vault nightly releases and the Settings update channel.
Scope: this repository. The CLI release workflow supplied reference behavior only.

Two read-only reviews covered pull request [81](https://github.com/lpm-dev/lpm-vault/pull/81):

- Correctness: Settings, Sparkle channel selection, release ordering, and recovery.
- Security and performance: signing, publishing permissions, artifact trust, and resource use.

| ID | Source | Category | Location | Claim | Evidence | Disposition | Coverage | Commit | PR status |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| CLIENT-001 | review_client | Correctness | `UpdateChecker.swift`, `AuthStatusView.swift` | An open update offer permits a channel change and clears its reminder. | The rendered picker regression failed in both sign-in states. Sparkle permits manual checks during an active session. | Verified | `settingsChannelPicker` covers disabled selection, preserved reminder and preference, and a fresh check after completion. | `8d3e8f1` | Open; not merged |
| CLIENT-002 | review_client, primary verification | Correctness | `UpdateChecker.swift`, Sparkle resume path | A deferred download bypasses channel filtering. Another app process can resume its installer. | The deferred-channel and reconstructed-driver regressions failed before their fixes. Sparkle resumes installers by bundle identifier. | Verified | `deferredDownloadKeepsChannel`, `pendingInstallerSurvivesRelaunch`, `nativeDeferredDownloadLifecycle`, `automaticInstallerLifecycle` | `8d3e8f1` | Open; not merged |
| RELEASE-001 | review_release | Correctness | `release_channels.publish` | A queued nightly can replace newer stable source with a higher build number. | Four regression cases failed before the guard: first or later nightly, with behind or diverged stable ancestry. | Verified | `test_queued_nightly_cannot_replace_a_newer_stable_source`; older nightly feed recovery remains possible. | `8d3e8f1` | Open; not merged |
| CLIENT-003 | review_client | Correctness | `SparkleUpdateDriver.clearPendingUpdate` | A stale cycle clears another app instance's new installer marker. | Abort, fresh presentation, and fresh-offer Skip each failed the callback-order regression before the ownership fix. | Verified | `staleCyclePreservesAnotherInstaller`, `preparationGenerationsRemainIndependent` | `8d3e8f1` | Open; not merged |

Both reviewers reviewed the fixes and confirmed that all findings are resolved.
They reported no remaining correctness, security, or performance findings in their assigned surfaces.
The initial deferred-download lead and the later cross-process report share canonical finding CLIENT-002.

Final totals: 4 received, 4 verified and fixed, 0 rejected, 0 externally blocked, and 0 pending.

Final local checks passed: 1,002 Swift tests, 6 cooperative executor tests, 49 Python tests, and 40 shell assertions.
The universal Release build, update settings check, nested signing, and workflow lint passed with zero build warnings.
Unchanged web surfaces passed 21 browser tests, 18 route tests, and 3 proxy tests.
The pinned env engine reproduction also passed.
