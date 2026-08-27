# Local macOS release

`release-app.sh` creates a signed and notarized direct-distribution release on a trusted Mac. It sends temporary submissions to Apple's notary service, but it does not upload artifacts to release hosting, create a GitHub release, or publish an update feed.

## One-time setup

Install the Developer ID Application certificate and its private key in the login Keychain. The default identity is:

```text
Developer ID Application: Tolga Ergin (823S8YKMRW)
```

Create and download a Developer ID provisioning profile for macOS App ID
`dev.lpm.vault`. The profile must authorize Team-scoped Keychain group
`823S8YKMRW.*`. The app signature remains restricted to
`823S8YKMRW.dev.lpm.vault.shared`. Keep the profile outside this repository and
export its path before local builds or releases:

```bash
export LPM_VAULT_PROVISIONING_PROFILE=/secure/path/LPM-Vault.provisionprofile
```

The profile is required because Keychain Sharing is a restricted entitlement.
The build embeds the profile in the app before applying the Developer ID
signature.

Store App Store Connect API credentials in a named `notarytool` Keychain profile. Do not store the key or its values in this repository.

```bash
xcrun notarytool store-credentials lpm-vault \
  --key /secure/path/AuthKey_KEYID.p8 \
  --key-id KEYID \
  --issuer ISSUER_UUID
```

Apple validates the credentials before it saves the profile. The profile stores the credential in the Keychain, not in the release script.

## Create a release

Run the unit tests for the release tooling:

```bash
cd LPMVault
./Scripts/Tests/release-tooling-tests.sh
./Scripts/audit-tls-pins.sh
```

Create a local release with an output directory that does not already exist:

```bash
cd LPMVault
./release-app.sh \
  --version 1.0.0 \
  --build 1 \
  --notary-profile lpm-vault
```

You can set `NOTARYTOOL_PROFILE=lpm-vault` instead of passing the option. For a temporary or isolated build machine, the script also accepts `--notary-key`, `--notary-key-id`, and `--notary-issuer`. Never commit the `.p8` key.

The default target is `release/LPM-Vault-VERSION+BUILD/`. The script refuses to overwrite an existing target. It produces:

- A Developer ID-signed, notarized, and stapled DMG with an Applications shortcut.
- A universal update ZIP that contains the signed, notarized, and stapled app. This archive format can be used by a future Sparkle 2 feed.
- `checksums.txt` with SHA-256 hashes for both distributable artifacts.
- `release-manifest.json` with release metadata, file sizes, hashes, and Apple submission IDs.
- Diagnostic logs for the build, signing checks, notarization, stapling, and Gatekeeper.

The release fails unless all checks pass. These checks include the bundle ID, version, build, minimum macOS version, `arm64` and `x86_64` architectures, Developer ID team, secure timestamp, Hardened Runtime, notarization ticket, and Gatekeeper assessment. App Sandbox remains disabled because LPM Vault interoperates with the CLI through the user's Keychain and `~/.lpm` files.

The update ZIP is ready for a future Sparkle integration, but Step 1 does not create an appcast or a Sparkle EdDSA signature. Do not publish either artifact until the public release and update design is complete.
