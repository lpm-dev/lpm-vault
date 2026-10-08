<p align="center">
  <a href="https://vault.lpm.dev"><img src="web/public/lpm-vault.svg" alt="LPM Vault logo" height="120"></a>
</p>

<h1 align="center">LPM Vault</h1>

<p align="center">Project environment variables and secrets for your Mac.</p>

<p align="center">
  <a href="https://vault.lpm.dev/download">Download for Mac</a> ·
  <a href="https://cli.lpm.dev/docs/dev/lpm-vault">Documentation</a> ·
  <a href="https://github.com/lpm-dev/lpm-vault/releases">Releases</a> ·
  <a href="SECURITY.md">Security</a>
</p>

LPM Vault is a native macOS app for project environment variables and secrets.
It stores local values in the macOS Keychain and shares them with the signed LPM CLI.
Optional encrypted sync connects personal and organization env projects through [LPM.dev](https://lpm.dev).

![LPM Vault compares dummy variables across three environments](docs/assets/vault-workspace.png)

The screenshot uses dummy project data. It contains no real credentials.

## Install

LPM Vault supports **macOS 14 or later**, on **Apple silicon and Intel**.
Touch ID is optional. You can unlock the app with your Mac login password.

If protected state cannot load, the locked screen explains the recovery action.
Failed project loads show **Retry** and a support link. The app keeps unreadable state protected.

1. [Download the current installer](https://vault.lpm.dev/download).
2. Open the DMG.
3. Drag **LPM Vault** into **Applications**.
4. Open **LPM Vault**.

Official releases include Developer ID signatures and Apple notarization.
The application menu provides **Check for Updates…**.
Sparkle asks before it enables background update checks.

## Updates

**Settings → Updates** shows the installed version and the update channel.
Stable installations use **Stable** by default. Direct nightly installations use **Nightly** by default.
Vault keeps your channel choice across app updates and account changes.

**Stable** offers stable releases. **Nightly** also offers development releases and newer stable releases.
Nightly releases can contain bugs. Both channels use signed, notarized installers and signed update feeds.
Changing the channel does not install an update or change your stored secrets.
The channel picker waits until the current update session ends.
If Sparkle keeps a downloaded or prepared update, install or skip it before changing channels.
Use **Check for Updates…** to reopen that update.

If you switch from Nightly to Stable, Vault keeps the installed nightly until a newer stable build is available.
The settings explain this state. Vault does not downgrade your app automatically.

The release workflow runs nightly at **03:37 UTC**. It publishes only when `main` advances beyond the published nightly.
Release maintainers can also run the workflow manually from `main`.
See [Release channels](docs/release-channels.md) for the publishing and recovery procedures.

## What you can do

- Manage project variables across multiple environments.
- Compare values and find missing keys in the environment matrix.
- Review `.env` imports with values hidden. Keep existing values or select individual replacements.
- Export `.env` files.
- Unlock with Touch ID or your Mac login password.
- Use local values from `lpm env`, `lpm dev`, and `lpm run`.
- Sync encrypted data to personal or organization env projects.
- Choose System, Light, or Dark appearance.

Local project storage does not require an LPM.dev account.
Cloud sync requires an account and the permissions for the selected project.

Use **Settings → Sign in with browser** to connect your account.
After browser verification, return to the app to check the connection status.
The local callback page provides retry instructions if verification fails. It loads no external resources.

## Start with a project

1. Unlock the app.
2. Create an env project.
3. Add environments, then add variables or import an `.env` file into each environment.
4. Use **All variables** to compare environments.
5. To connect the CLI, use **Connect CLI** for the selected project.

Click anywhere in a key cell to open its inspector.
Drag a column boundary in the table header to resize the column.
Both **All variables** and each environment table support this gesture.
Each project keeps its column widths during the session, including visits to Settings and project reloads.

Select **Schema** under a project to see the rules its `lpm.json` declares for each key, such as required keys, formats, defaults, and keys exposed to the browser.
Rules are read-only in LPM Vault; edit them in `lpm.json`, and the LPM CLI enforces them.
Rules inherited from another schema file or a preset show where they come from.
The inspector lists the selected key's rules, read-only, between its values and its description.
Keys whose rules make them public, because frameworks expose them to the browser, show a globe and their values unmasked; every other value stays masked until you reveal it.
When you add a variable, typing a name suggests declared keys that are not yet set in the selected environments; use the arrow keys and Return, or click one, to pick it and see its rules beside the value.
LPM Vault checks each environment's stored values against these rules with the same engine the LPM CLI uses.
A value that fails a rule gets a red marker and an underline. Its tooltip shows the reason.
A missing required value reads Required. A value that the CLI fills from a schema default reads (default).
The Invalid chip and the Invalid values smart view list the keys that fail.
An environment's table shows a banner for each failing group.
An environment without values of its own uses `.env`'s values in the LPM CLI. The app checks those values against the requested environment's rules and shows any failures.
Raw text shows stored assignments. Required keys and schema defaults also appear in the table.
The check covers stored values. The LPM CLI can also read project `.env` files and shell variables when it runs a command.
The inspector outlines failing values in red and lists problems under RULES.
It checks pending value edits and key renames before you save.

The connection sheet links a project directory through `lpm.json`.
Install the [official LPM CLI](https://cli.lpm.dev/docs/installation) for shared Keychain access.
Then run a project script:

```sh
lpm run dev
```

Connect CLI shows commands for the selected environment, with an explicit `--env` flag.
Run these commands from the linked project folder.
The flag overrides script environment settings. Existing `lpm.json` aliases still apply.
If an alias selects another environment, the sheet explains the configuration change required before it shows commands.
An empty environment uses default vault values when a script runs.
Linking a folder does not install the CLI.

See the [app guide](https://cli.lpm.dev/docs/dev/lpm-vault) and [env guide](https://cli.lpm.dev/docs/dev/env) for environment selection.

## CLI approval

Select a project. Use **CLI approval** beside **All variables** to control CLI access for that project.

- **Off:** `lpm run` injects env values automatically.
- **On:** macOS requires Touch ID or your Mac login password before Keychain releases env values.

If authentication fails or you cancel it, LPM stops before it runs lifecycle hooks or the main script.

The sidebar shows a folder for automatic CLI access and a lock for required CLI approval.
Change the setting while the app is unlocked. This change requires no extra authentication prompt.
The setting applies to every environment in the selected project on this Mac.

The app's **Lock** button hides secrets and clears the app's authentication context.
It does not change CLI approval.

CLI approval protects secret reads and temporary records used during updates.
It does not revoke values that a process already received.

## Changes from the CLI

When you return to the unlocked app, it reloads local changes from the LPM CLI.
Use **Refresh** to reload changes while the app stays active.
This reads project metadata, CLI approval, and secrets for the selected project. It does not contact the cloud.

Unsaved editor values remain in the editor. A changed or deleted secret shows a conflict and blocks Save.
Copying and exporting wait for a refresh in progress, so they use the reloaded values.
If a refresh fails, copying, revealing, and exporting pause until **Retry** succeeds.
Automatic refresh does not extend the idle-lock timer. The locked app does not read secret values.

## Security and privacy

Local secrets use the Data Protection Keychain on this Mac. They do not sync through iCloud Keychain.
Cloud sync encrypts values on your Mac before upload. It preserves named empty environments, including projects with no keys.
Exported `.env` files and copied values require separate protection.

The Mac app sends no analytics.
The website uses limited analytics and provides an opt-out control.
Read [PRIVACY.md](PRIVACY.md) for network activity and website privacy.

Read the [security model](https://cli.lpm.dev/docs/infra/secrets-vault) for storage and sync details.
Report suspected vulnerabilities privately through [SECURITY.md](SECURITY.md).

## Support and contributions

Read [SUPPORT.md](SUPPORT.md) for troubleshooting and issue reporting.
Read [CONTRIBUTING.md](CONTRIBUTING.md) for development setup and CI checks.
Signed builds and release procedures are in [RELEASING.md](LPMVault/RELEASING.md).

Source builds need their own signing identity and storage contract for Keychain access.
Use the official installer for production secrets and CLI integration.

LPM Vault is part of [LPM CLI](https://cli.lpm.dev), [LPM.dev Registry](https://lpm.dev), and [LPM Firewall](https://firewall.lpm.dev).

## License

Dual-licensed under **MIT OR Apache-2.0**, at your option.
See [LICENSE-MIT](LICENSE-MIT) and [LICENSE-APACHE](LICENSE-APACHE).
Third-party components retain their own licenses.
