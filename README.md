# LPM Vault

LPM Vault is a native macOS app for project env values. It shares local Keychain data with the LPM CLI.

## CLI approval

Select a project. Use **CLI approval** beside **All variables** to control CLI access for that project.

- **Off:** `lpm run` injects env values automatically, as before.
- **On:** macOS requires Touch ID or your Mac login password before Keychain releases env values.

If authentication fails or you cancel it, LPM stops before it runs lifecycle hooks or the main script.

The app requires authentication to change CLI approval. The setting applies to every environment in the selected project on this Mac.

The app's **Lock** button hides secrets and clears the app's authentication context. It does not change CLI approval.

CLI approval protects secret reads and temporary records used during updates. It does not revoke values that a process already received.

For build and release instructions, read [RELEASING.md](LPMVault/RELEASING.md).
