# Contributing to LPM Vault

LPM Vault contributions must preserve secret handling, the signed CLI contract, and update integrity.
Keep changes focused and include tests for new features and behavior changes.
For a bug fix, add a failing regression test before you change production code.

## Development setup

Development requires macOS and the full Xcode installation.
The Swift package requires Swift 6.2 or later.
CI uses macOS 15 and Xcode 26.2.
Node.js and Python 3 are required for website and release-tooling tests.
XcodeGen is required only if you regenerate the committed Xcode project.

1. Clone the repository.
2. Select the full Xcode installation as the developer directory.
3. Resolve the committed Swift package dependencies.

```sh
git clone https://github.com/lpm-dev/lpm-vault.git
cd lpm-vault
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
swift --version
swift package --package-path LPMVault resolve
```

The committed package files pin Sparkle.
Do not update dependencies as part of an unrelated change.

## Source builds and Keychain access

The unsigned build below verifies compilation. It is not a production installer.
An unsigned or ad-hoc build cannot access the official shared Keychain group.
An independent app requires its own signing identity and storage contract.

`build-app.sh` and `release-app.sh` require signing credentials and a valid provisioning profile.
They enforce the official shared Keychain contract.
Do not use those scripts as the initial contributor setup.
Do not remove signature checks or entitlements to make a build access production credentials.

Use mocks and temporary fixtures for tests.
Use the [official installer](https://vault.lpm.dev/download) for real secrets and CLI integration.
Read [RELEASING.md](LPMVault/RELEASING.md) for authorized signed builds.

## Tests and build checks

Run relevant tests while you develop a change.
Swift Testing accepts a test or suite name through `--filter`:

```sh
swift test --package-path LPMVault --disable-automatic-resolution -Xswiftc -warnings-as-errors --filter ConnectCLITests
```

Before you push a branch, run the whole Swift suite locally, native UI tests included; on an Apple silicon Mac it takes about six minutes, most of them the UI suite:

```sh
swift build --build-tests --package-path LPMVault -Xswiftc -warnings-as-errors && swift test --package-path LPMVault --skip-build
```

Every push to a pull request starts two or three jobs on macOS runners, which are often in short supply, so push a set of changes that has passed this run rather than one fix at a time.

Pull request checks run every Swift test except the native UI suite, `SheetInteractionTests`.
They run those tests a second time on a one-thread cooperative pool, so work that blocks a cooperative thread, or waits on a task that needs one, deadlocks there rather than only on a runner with few cores. After a build, run that check locally from the repository root; it takes a few seconds:

```sh
bash LPMVault/Scripts/Tests/cooperative-executor-tests.sh
```

The native UI suite's tests open real windows and run one at a time, so they are not a required check. The [UI regressions workflow](.github/workflows/ui.yml) runs them before every release, on demand from the Actions tab, and for a pull request labeled `ui-tests`.
It also runs them, without the label, for a pull request that changes the suite's tests, the test support code they can use, or how the suite runs; `LPMVault/Scripts/ui-suite-changes.py` decides.
The [post-merge checks](.github/workflows/post-merge.yml) run them for every commit on `main`.
Label a pull request `ui-tests` when it changes what a sheet or view shows, or how it responds to input. Where the suite does run for a pull request, it takes a quarter of an hour or more to answer, so the local run before you push is the one to act on.
The suite runs on one runner, in the order it runs locally. An on-demand run can take a `filter`, a regular expression for the identifiers of the tests to run, and runs only those. Use it to check one test on the runners' macOS without waiting for the whole suite:

```sh
gh workflow run ui.yml --ref <branch> -f filter='VaultProjectOrderTests/dragAutoscrolls'
```
Native UI tests belong in `SheetInteractionTests` or a suite nested in it; a test that opens a test window or reads text elsewhere fails.

UI tests find and read views through the accessibility tree, as VoiceOver does: `waitForText`, `text()`, `click`, `waitForElement(saying:)` and `lines(in:)` on `SheetTestHost`, built on `AccessibilityTree`. Match what a view says, its accessibility label or text; letter case doesn't count, since some text is drawn uppercased. A control that shows only an icon needs a label, which is also how VoiceOver users know it. Don't read text from pixels: check pixels only for what's visual, such as color, alignment or overlap. Secret values are kept out of the tree by design, so assert what their labels say, such as "Current value for TOKEN revealed visually" or "values hidden", rather than the value.

Every test waits for the state its next step needs, never for a length of time; a loaded runner can pause the test process for tens of seconds, and a test has to pass then too. `waitUntil` in `LPMVault/Tests/Waiting.swift` checks a condition until it holds; its limit, `testWaitLimit`, only bounds a failure. Better still is a gate the test controls, such as a mock that holds a request until the test releases it, which says exactly when each step happens. Code that measures the time between events takes a clock, and a test moves a `ManualClock` by hand. Check that something doesn't happen with `quietPeriod()` only when no state says the work that could do it is over. Don't assert how long something took: count what a fast path does differently, such as how often it rebuilds an index, or give it an input that a slower algorithm couldn't finish within the test's time limit.

The pull request's checks run the rest, and answer in about ten minutes. Run these locally, from the repository root, only when your change touches what they check: the release tooling in `LPMVault/Scripts`, the workflows, the site in `web/`, or the Xcode project and its build settings:

```sh
bash LPMVault/Scripts/Tests/release-tooling-tests.sh
python3 -m unittest discover -s LPMVault/Scripts/Tests -p 'test_*.py'
npm ci --prefix web --ignore-scripts
npm run build:sdk --prefix web
git diff --exit-code -- web/public/vendor
npx --prefix web playwright install chromium
node --test web/tests/test_*.cjs
python3 web/tests/test_routes.py
python3 web/tests/test_proxy.py

xcodebuild -project LPMVault/LPMVault.xcodeproj -scheme LPMVault \
  -configuration Release -destination 'generic/platform=macOS' \
  -derivedDataPath build-check CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO \
  SWIFT_TREAT_WARNINGS_AS_ERRORS=YES GCC_TREAT_WARNINGS_AS_ERRORS=YES build
python3 LPMVault/Scripts/verify-update-config.py \
  'build-check/Build/Products/Release/LPM Vault.app/Contents/Info.plist'
bash LPMVault/Scripts/sign-sparkle.sh 'build-check/Build/Products/Release/LPM Vault.app' - --timestamp=none
codesign --force --sign - 'build-check/Build/Products/Release/LPM Vault.app'
codesign --verify --deep --strict 'build-check/Build/Products/Release/LPM Vault.app'
```

The ad-hoc signature checks verify the bundle structure. They do not grant shared Keychain access.
The [CI workflow](.github/workflows/ci.yml) is authoritative for the toolchain and required checks. Its Swift steps live in the [Swift tests workflow](.github/workflows/swift-tests.yml), which it shares with the UI regressions, and its release bundle steps in the [release bundle workflow](.github/workflows/release-bundle.yml).
A push to a pull request cancels the runs of its earlier commit, in both workflows.
The checks rebuild the bundled env engine from its pinned source for a pull request only when it changes the engine in `LPMVault/Vendor/EnvEngine` or how the rebuild runs; `LPMVault/Scripts/engine-changes.py` decides. Every run before a release and each night rebuilds it, and every run checks the bundle against the hashes in its `provenance.json`.

macOS runners are the scarce resource, so each stage runs only what the one before it didn't:

- A pull request's checks compile the release bundle for arm64 only.
- The merge queue runs the same checks on the pull request merged with `main`, before it lands. When `main` hasn't moved since the pull request's own run passed, the merge group holds the very tree that run checked, and the queue skips the macOS jobs; `LPMVault/Scripts/ci-passed-tree.py` finds that run, and only a run of a branch in this repository counts.
- Every commit on `main` passed the queue as that same commit, so the [post-merge checks](.github/workflows/post-merge.yml) run only what the queue left out: the native UI suite and the universal bundle, with its x86_64 half. They are not required checks.
- A release, and the nightly build, runs everything.

GitHub gives up on a job that no hosted runner takes within about 15 minutes, and the run fails though nothing ran. The [runner retry workflow](.github/workflows/runner-retry.yml) runs such a run's failed jobs again, up to twice. It leaves alone a run in which a job ran and failed, so it never turns a failing test green, and it can't rerun a merge group, whose pull request has to be queued again.
Builds must complete with zero warnings.

Keep Swift tests in `LPMVault/Tests`, release-tooling tests in `LPMVault/Scripts/Tests`, and website tests in `web/tests`.
Use names that describe the expected behavior.
Do not use live credentials or private project data in fixtures, logs, or screenshots.

## Documentation and releases

Update relevant documentation in the same change as user-facing behavior.
Public CLI language uses **env**. The macOS app retains the product name **LPM Vault**.
Keep examples consistent with the [app guide](https://cli.lpm.dev/docs/dev/lpm-vault) and the signed CLI contract.

Each pull request needs one primary release-note label:
`breaking-change`, `security`, `enhancement`, `bug`, `compatibility`, `performance`, `documentation`, `dependencies`, or `internal`.
Use `skip-changelog` only for changes that do not belong in release notes.
Maintainers apply labels. Contributors can propose a label in the pull request.
The [release configuration](.github/release.yml) groups merged pull requests by label.

Prepare short user-facing highlights and any upgrade instructions before you tag a release.
Generated notes list pull requests. They do not replace migration guidance.
After publication, add reviewed highlights and upgrade instructions to the release description.
Keep the generated pull request list below that guidance.
Use [RELEASING.md](LPMVault/RELEASING.md) for the release checklist.

## Pull requests

Create a descriptive branch and open a pull request against `main`.
Do not push directly to `main`.
Include the problem, solution, user impact, and exact validation commands with their results.
Describe security and performance implications for affected paths.
Explain any signing or CLI compatibility change.

CI must pass before merge.
Green CI does not replace maintainer approval.
Never enable automatic merge.

Source comments explain non-obvious invariants or contracts. They do not restate the code or record review history.

## License

LPM Vault is dual-licensed under MIT OR Apache-2.0, at your option.
See [LICENSE-MIT](LICENSE-MIT) and [LICENSE-APACHE](LICENSE-APACHE).
Third-party components retain their own licenses.

Report vulnerabilities privately through [SECURITY.md](SECURITY.md).
