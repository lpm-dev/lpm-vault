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

Before you open a pull request, run the current CI checks from the repository root:

```sh
swift test --package-path LPMVault --disable-automatic-resolution -Xswiftc -warnings-as-errors
bash LPMVault/Scripts/Tests/release-tooling-tests.sh
python3 -m unittest discover -s LPMVault/Scripts/Tests -p 'test_*.py'
npm ci --prefix web --ignore-scripts
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
The [CI workflow](.github/workflows/ci.yml) is authoritative for the toolchain and required checks.
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
