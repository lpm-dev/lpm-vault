# Signed releases and updates

LPM Vault uses Sparkle 2.10.0 for direct macOS updates. The app supports macOS 14 or later on Apple silicon and Intel.

## Public addresses

| Address | Purpose |
| --- | --- |
| `https://vault.lpm.dev/` | Product page |
| `https://vault.lpm.dev/download` | Current DMG installer |
| `https://vault.lpm.dev/releases/vVERSION/FILENAME` | Immutable release artifact |
| `https://vault.lpm.dev/updates/appcast.xml` | Signed Sparkle feed |

Coolify serves the website from `web/Dockerfile`, with the repository root as the build context. The container listens on port 8080. Its health endpoint is `/health`.

For an initial website deployment from an open pull request, disable automatic deployment and pin a commit that passed CI. After the approved merge, select `main`, clear the commit pin, and enable automatic deployment.

Cloudflare routes `vault.lpm.dev` to the Coolify server. Coolify must have the domain `https://vault.lpm.dev` and a valid origin certificate.

The download routes redirect to public GitHub release assets. The repository must be public before downloads can work without authentication. No GitHub token belongs in the app or website.

GitHub release immutability protects each published version. The current installer and feed use uncached redirects. Published releases contain all assets before they become visible.

## Signing boundaries

The following identifiers remain stable across updates:

| Item | Value |
| --- | --- |
| Apple team | `823S8YKMRW` |
| Vault bundle | `dev.lpm.vault` |
| CLI bundle | `dev.lpm.cli` |
| Shared Keychain group | `823S8YKMRW.dev.lpm.vault.shared` |

Vault and the official CLI use the same narrow Keychain group. Their separate Developer ID profiles authorize their respective application identifiers. Sparkle helpers receive no Keychain group entitlement.

Public source code and a copied entitlement file cannot grant access to this group. Apple validates the signature and provisioning profile. Source builds need their own identity and storage contract.

The app requires a signed feed and verifies each archive before extraction. The feed uses a signed DMG enclosure. A separate universal ZIP supports manual distribution.

Sparkle asks the user whether to enable background update checks. Automatic downloads start disabled. The application menu provides **Check for Updates…**. Debug builds disable production updates.

When Sparkle offers a new version, **Update available** appears beside **Lock**. The button opens the current update window. The reminder clears when the update session ends, including after **Skip This Version** or **Remind Me Later**.

## Existing credential gap and migration

Earlier auth queries used the `lpm-cli` service without selecting the shared Data Protection Keychain group. Matching service names did not provide the intended access boundary.

Vault and CLI now select the Data Protection Keychain and the exact shared group. They disable synchronization for these credentials. New credentials use `WhenUnlockedThisDeviceOnly` accessibility.

Migration runs under the existing cross-process credential lock:

1. Read the older credential only when its authority names the older Keychain backend.
2. Compare its SHA-256 digest with the authority record.
3. Write the shared credential and read it back.
4. Save `shared_keychain` authority with `legacy_keychain_cleanup_pending` enabled.
5. Delete the older credential.
6. Clear the cleanup marker.

A failed copy preserves the old authority. A failed cleanup preserves the shared authority and retries later. It never imports an old credential after authority switches.

Older clients reject `shared_keychain` authority. Keep Vault and CLI current after migration. A credential without valid authority requires a new login. Vault does not read the CLI encrypted-file fallback.

## GitHub configuration

The release workflow requires these repository Actions secrets:

| Secret | Content |
| --- | --- |
| `APPLE_DEVELOPER_ID_P12_BASE64` | Base64 Developer ID Application export, including its private key |
| `APPLE_DEVELOPER_ID_P12_PASSWORD` | Export password |
| `APPLE_VAULT_PROVISIONING_PROFILE_BASE64` | Base64 Vault Developer ID profile |
| `APPLE_NOTARY_KEY_BASE64` | Base64 Apple API private key |
| `APPLE_NOTARY_KEY_ID` | Apple API key identifier |
| `APPLE_NOTARY_ISSUER_ID` | App Store Connect issuer UUID |
| `SPARKLE_PRIVATE_KEY` | Dedicated Sparkle EdDSA private key |

Keep a secure backup of the signing keys. The local Sparkle account is `dev.lpm.vault.sparkle`. The public key is committed in `Info.plist` and verified during packaging.

The build runner imports the Developer ID export into a temporary Keychain. Cleanup restores the original search list and deletes the temporary signing files. Coolify needs no signing secrets.

## Publish a release

### Verify credentials before publication

The **Verify signed release** workflow uses the repository secrets to build and notarize test installers. It works while the repository is private.

Run it manually with a test version and build number. Before the workflow reaches `main`, push a `release-check-*` tag on the reviewed branch:

```bash
git tag release-check-1.0.0-build3
git push origin release-check-1.0.0-build3
```

This tag runs the full CI gates before signing. It does not start the production release workflow or create a GitHub release.

Download the `vault-verified-installers` workflow artifact for local testing. GitHub retains it for seven days. It contains installers, checksums, the signed feed, and the release manifest. Signing credentials and diagnostic logs are excluded.

GitHub cannot return saved secret values to a local build. A local build uses an installed Developer ID identity and a valid local notarization profile or API key.

### Publish verified artifacts

1. Update `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `project.yml`.
2. Increase both values beyond the latest published release.
3. Run `xcodegen generate --spec LPMVault/project.yml` from the repository root.
4. Submit the change through a pull request.
5. After the pull request passes CI and receives merge approval, merge it.
6. Tag the merged commit with `vMAJOR.MINOR.PATCH`.
7. Push that tag.

The tag starts the CI gates again. The release job requires a commit from `main`, a public repository, and immutable releases.

The job signs every Sparkle component, signs Vault, notarizes the app, staples its ticket, and verifies Gatekeeper acceptance. It repeats notarization for the DMG. It then generates and verifies the signed feed and archive signatures.

The workflow publishes these assets together:

- `LPM-Vault-VERSION.dmg`
- `LPM-Vault-VERSION-macos-universal.zip`
- `LPM-Vault.dmg`
- `appcast.xml`
- `checksums.txt`
- `release-manifest.json`

If publication stops with a draft release, inspect its assets before recovery. The workflow refuses to replace an existing release. Published immutable assets cannot be replaced.

## Local verification

From the repository root:

```bash
swift test --package-path LPMVault --disable-automatic-resolution -Xswiftc -warnings-as-errors
bash LPMVault/Scripts/Tests/release-tooling-tests.sh
python3 -m unittest discover -s LPMVault/Scripts/Tests -p 'test_*.py'
python3 web/tests/test_routes.py
```

The signed interoperability test uses temporary accounts and the production Swift and Rust Keychain implementations:

```bash
export LPM_VAULT_PROVISIONING_PROFILE=/path/to/Vault.provisionprofile
export LPM_CLI_PROVISIONING_PROFILE=/path/to/CLI.provisionprofile
export CARGO_TARGET_DIR=/tmp/lpm-auth-interop-target
bash LPMVault/Scripts/Tests/signed-auth-interop.sh /path/to/rust-client
```

Rust writes a temporary credential. Swift reads and replaces it. Rust reads the replacement and deletes the test items.

For local release artifacts, configure notarization and run:

```bash
xcrun notarytool store-credentials lpm-vault-notary \
  --key /path/to/AuthKey.p8 --key-id YOUR_KEY_ID --issuer YOUR_ISSUER_UUID
export LPM_VAULT_PROVISIONING_PROFILE=/path/to/Vault.provisionprofile
export NOTARYTOOL_PROFILE=lpm-vault-notary
bash LPMVault/release-app.sh --version 1.0.0 --build 1
bash LPMVault/Scripts/fetch-sparkle-tools.sh /tmp/vault-sparkle-tools
bash LPMVault/Scripts/generate-appcast.sh LPMVault/release/LPM-Vault-1.0.0+1 /tmp/vault-sparkle-tools
```

Local scripts submit artifacts to Apple for notarization. They do not publish a GitHub release.

If an older profile fails authentication after an update, use a distinct profile name and verify it with `notarytool history`.

## First public release dependencies

The initial rollout requires verified signing credentials, public repository visibility, and the first notarized release. A product-page deployment alone does not make an installer available.

Before public launch, install the DMG on a clean Mac and verify Keychain access with the matching signed CLI. Then verify an update between two notarized builds through the public feed. This final end-to-end check needs two published release artifacts.
