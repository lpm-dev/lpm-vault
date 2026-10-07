# Env table interaction review ledger

Concept: key-cell selection and column resizing in the project matrix and environment tables.
Scope: this repository. Pull request: [82](https://github.com/lpm-dev/lpm-vault/pull/82).

The user requested one read-only subagent review.
`review_table_pr` reviewed correctness, security, and performance, then reviewed the fixes and OCR test update.
The primary agent reproduced every finding before the fix and made all changes.

| ID | Source | Category | Location | Claim | Evidence | Disposition | Coverage | Commit | PR status |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- |
| USER-01 | User | Correctness | `VaultContentView.swift`, `VaultMatrixRow` | Blank space in a key cell does not open the inspector. | Native clicks at 5 and 205 points into the key cell failed before the button label received its content shape. | Verified | `matrixKeyCellBlankSpace` | `6ec6925` | Open; unmerged |
| USER-02 | User | Correctness | `VaultContentView.swift`, both tables | Table columns cannot resize. | Both native-host cases failed because the resize targets did not exist. | Verified | `tableColumnResize`, `VaultTableColumnLayoutTests` | `6ec6925` | Open; unmerged |
| RT-01 | `review_table_pr` | Correctness | `VaultContentView.swift`, `VaultTableResizeHandles` | The inspector divider covers the final column handle. | Native hit tests selected the inspector instead of the final table handle in both views. A trailing gutter now separates the targets. | Verified | `finalColumnResizeTarget` covers both views, column growth, and horizontal scrolling to the end. | `e194813` | Open; unmerged |
| RT-02 | `review_table_pr` | Correctness | `VaultContentView.swift`, resize activity callback | Accessibility resizing does not postpone auto-lock. | The fake-clock regression retained the countdown and locked at the old deadline. Resize activity now reaches `recordUserActivity`. | Verified | `columnAccessibilityResetsAutoLock` covers both views, countdown clearing, and the next countdown wake time. | `e194813` | Open; unmerged |
| RT-03 | `review_table_pr` | Correctness | `VaultContentView.swift`, `VaultEnvironmentRow` | Both fixed badges consume the minimum key width and hide the key. | Before the fix, OCR found only UNSAVED and DIFFERS in the key column. Compact indicators preserve the visible key prefix. | Verified | `narrowKeyWithBothBadges`, with a rendered attachment | `e194813` | Open; unmerged |
| PT-01 | Primary agent | Correctness | `VaultContentView.swift`, table stacks | A table centers after all columns shrink. | Both rendered header tests measured a shift of more than 450 points. Leading stack alignment removes the shift. | Verified | `shrunkenTableAlignment` | `e194813` | Open; unmerged |
| CI-01 | CI and primary agent | Correctness | `WorkspaceInteractionTests.swift`, `waitForKeyOrder` | Complementary OCR results cannot establish the displayed key order. | CI recognized ZULU with fast mode and ALPHA with accurate mode. A fixture with those bounds failed the prior recognition rule. | Verified | `complementaryKeyRecognition` combines one snapshot and rejects reversed, missing, and merged rows. | `e194813` | Open; unmerged |

Final totals: 7 findings received, 7 verified and fixed, 0 rejected, 0 externally blocked, and 0 pending.
Subagent totals: 3 received, 3 verified and fixed, 0 rejected, 0 externally blocked, and 0 pending.
The final read-only pass found no remaining actionable findings.

Final local checks passed: 1,013 Swift tests and the universal Release build, with zero warnings.
Update configuration and nested signing checks passed on the final build.
The pinned env engine rebuild, 6 cooperative tests, 40 release shell assertions, and 49 Python tests also passed.
Unchanged web surfaces passed SDK regeneration, 21 browser tests, 18 route tests, and 3 proxy tests.

Column geometry takes O(column count) time and space. Rows use width lookup by column identity and retain lazy rendering.
No CLI, registry, secret storage, sync, or signing contract changed.
