# Local env integration

The native app, CLI, and registry must use the same protocol revision.
The app and CLI share account credentials and env data through the macOS Keychain.

## Signed macOS clients

Use Developer ID provisioning profiles for `dev.lpm.vault` and `dev.lpm.cli` from the same Apple team.
The profiles must authorize the shared Keychain group in each target's entitlements.

In the app repository, run:

```sh
LPM_VAULT_PROVISIONING_PROFILE=/path/to/vault.provisionprofile bash LPMVault/build-app.sh debug
```

In the CLI repository, run:

```sh
LPM_CLI_PROVISIONING_PROFILE=/path/to/cli.provisionprofile bash scripts/build-signed-macos.sh
```

The scripts validate the signing identity, profiles, and Keychain entitlements.
Unsigned builds cannot provide the shared Keychain integration.

## Local registry

Configure the registry with local Supabase credentials and apply its database migrations.
Use the registry's `.env.example` for the other required configuration.
For local env development, add these values to its ignored `.env.local`:

```dotenv
NEXT_PUBLIC_APP_URL=http://localhost:3000
VAULT_RESPONSE_SIGNING_KEY_ID=vault-test-rfc8032
VAULT_RESPONSE_SIGNING_PRIVATE_KEY=nWGxne_9WmC6hEr0kuwsxERJxWl7MmkZcDusAxyuf2A
```

This published RFC 8032 key is a development fixture.
The registry accepts it only in test mode or development mode with a loopback HTTP app URL.
Debug clients accept it only for responses from loopback HTTP addresses.
Release clients require the production signing key.

Run `npm run dev` in the registry repository.
Select **Use local** in the app's account settings.
The selector is available before sign-in in Debug builds.
For CLI commands, set `LPM_REGISTRY_URL=http://localhost:3000`.

## Round-trip checks

Use a disposable local account and synthetic values.
Personal cloud sync requires a Pro account.

1. Run the signed CLI's `login` command against the local registry.
2. Unlock the native app with Touch ID or your Mac password.
3. Use the CLI to store values in the default and production environments.
4. Push the project with the CLI.
5. Pull the project in the app.
6. Edit a value in the app, then push it.
7. Pull with the CLI and verify both environments with `env list --reveal`.
8. Pair the local dashboard and verify the same values in the browser.
9. Edit a value in the browser, then pull with both native clients.

The app and CLI keep separate sync checkpoints.
The app can report **Not synced** before its first successful sync, even when the CLI already uploaded the project.
Pull before the first app edit to establish its checkpoint.

The app's **Pull & Merge** action keeps local-only keys and uses cloud values for conflicts.
It then pushes the merged result.
**Force Push** replaces cloud values with local values.

## Organization round trip

Use a disposable organization with an owner and a maintainer.
Each account must register its sharing key through an organization pull or share.
Login alone does not register this key.

1. Sign in as the owner and run `lpm env share --org <slug>`.
2. Complete password verification and approve the listed recipient fingerprints.
3. Select the organization in the native app and open its import list.
4. If the project already exists under Personal, select **Move here**, then **Move and merge**.
5. Edit a value in the app and select **Share**.
6. Pull with the CLI and verify the value.
7. Sign in as the maintainer and run `lpm env pull --org <slug>`.
8. Complete account verification to register the maintainer's sharing key.
9. Sign in as the owner and share again. Approve the updated recipient list.
10. Sign in as the maintainer, pull, edit a value, then run `lpm env share --org <slug>`.
11. Leave the organization through the maintainer's dashboard account.
12. Confirm that the departed member cannot pull the organization project.
13. Sign in as the owner and run `lpm env rotate-key --org <slug>`.
14. Pull in the app and confirm that both environments retain their values.

**Move and merge** changes the project's local sidebar association.
It preserves its local name, path, local-only keys, and account-specific sync checkpoints.
Cloud values replace conflicting local values. This action does not upload data.

After a CLI account change, the app can reject a sync and clear its old account state.
Sign in again through the app's account settings before retrying.

## Validation limits

Local checks cover the signed app, signed CLI, dashboard, local registry, and local Supabase database.
Use a database with the registry's current base schema before applying the env migrations.
Historical bootstrap problems must not be repaired by editing applied migration files.

The historical baseline also includes manual SQL outside `db/migrations`:

- Install `pgcrypto`, `pg_trgm`, and `vector` in the `extensions` schema.
- Apply `db/sql/0002_ai-search-columns.sql`, then `db/sql/0005_search-vector-use-settings-tags.sql`, before original migration 0158.
- Use the registry auditor's existing list of acknowledged duplicate historical migrations.
- On an empty baseline, validate the ZIP metadata constraint after creating its table.

Use a separate empty database for original-history verification.
Never replay old migrations below an existing database's migration watermark.
After preparing the baseline, run `npm run db:push`, then `npm run db:audit-migrations`.
All three blocking audit counts must be zero.

The registry's vendor acceptance suite needs its external development Supabase, Stripe, Cloudflare, R2, and Worker configuration.
Local sync checks do not validate those deployments.
Organization browser decryption and organization OIDC access are unavailable in the current product contract.
