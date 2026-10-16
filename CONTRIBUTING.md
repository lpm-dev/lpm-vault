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

Before you push a branch, run the whole Swift suite locally, native UI tests included; on an Apple silicon Mac it takes about two minutes:

```sh
swift test --package-path LPMVault --disable-automatic-resolution -Xswiftc -warnings-as-errors
```

Pull request checks run every Swift test except the native UI suite, `SheetInteractionTests`.
They run those tests a second time on a one-thread cooperative pool, so work that blocks a cooperative thread, or waits on a task that needs one, deadlocks there rather than only on a runner with few cores. After a build, run that check locally from the repository root; it takes a few seconds:

```sh
bash LPMVault/Scripts/Tests/cooperative-executor-tests.sh
```

The native UI suite's tests open real windows and run one at a time, so the [UI regressions workflow](.github/workflows/ui.yml) runs them after every merge to `main`, before every release, on demand from the Actions tab, and for a pull request labeled `ui-tests`.
Label a pull request `ui-tests` only when it changes what a sheet or view shows, or how it responds to input; the local run before you push covers the rest.
An on-demand run can take a `filter`, a regular expression for the identifiers of the tests to run, and runs only those, on one runner, in a few minutes. Use it to check one test on the runners' macOS without waiting for every shard:

```sh
gh workflow run ui.yml --ref <branch> -f filter='VaultProjectOrderTests/dragAutoscrolls'
```
Native UI tests belong in `SheetInteractionTests` or a suite nested in it; a test that opens a test window or reads text elsewhere fails.

UI tests find and read views through the accessibility tree, as VoiceOver does: `waitForText`, `text()`, `click`, `waitForElement(saying:)` and `lines(in:)` on `SheetTestHost`, built on `AccessibilityTree`. Match what a view says, its accessibility label or text; letter case doesn't count, since some text is drawn uppercased. A control that shows only an icon needs a label, which is also how VoiceOver users know it. Don't read text from pixels: check pixels only for what's visual, such as color, alignment or overlap. Secret values are kept out of the tree by design, so assert what their labels say, such as "Current value for TOKEN revealed visually" or "values hidden", rather than the value.

Before you open a pull request, also run the rest of the CI checks from the repository root:

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
The [CI workflow](.github/workflows/ci.yml) is authoritative for the toolchain and required checks; the Swift steps live in the [Swift tests workflow](.github/workflows/swift-tests.yml) it shares with the UI regressions.
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
