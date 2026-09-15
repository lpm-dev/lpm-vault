#!/bin/bash
set -euo pipefail

vault_root="$(cd "$(dirname "$0")/../.." && pwd)"
cli_root="${1:?Usage: signed-auth-interop.sh CLI_REPOSITORY}"
: "${LPM_VAULT_PROVISIONING_PROFILE:?Vault profile path required}"
: "${LPM_CLI_PROVISIONING_PROFILE:?CLI profile path required}"
: "${CARGO_TARGET_DIR:?Use an isolated Cargo target directory}"
identity='Developer ID Application: Tolga Ergin (823S8YKMRW)'
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
python3 - "$CARGO_TARGET_DIR" <<'PY'
import shutil, sys
from pathlib import Path
path = Path(sys.argv[1])
while not path.exists():
    path = path.parent
if shutil.disk_usage(path).free < 10 * 1024**3:
    raise SystemExit('At least 10 GiB free disk space is required')
PY
(cd "$cli_root" && cargo +1.94.0 test --locked -p lpm-auth --lib --no-run --message-format=json > "$work/cargo.json")
test_binary="$(jq -r 'select(.reason == "compiler-artifact" and .target.name == "lpm_auth" and .profile.test) | .executable // empty' "$work/cargo.json")"
[ -x "$test_binary" ]
for product in Vault CLI; do
    app="$work/$product.app"
    mkdir -p "$app/Contents/MacOS"
    bundle_id=dev.lpm.vault
    if [ "$product" = CLI ]; then bundle_id=dev.lpm.cli; fi
    python3 - "$app/Contents/Info.plist" "$bundle_id" <<'PY'
import plistlib, sys
from pathlib import Path
Path(sys.argv[1]).write_bytes(plistlib.dumps(dict(CFBundleIdentifier=sys.argv[2], CFBundleExecutable='probe', CFBundlePackageType='APPL')))
PY
done
swiftc -warnings-as-errors "$vault_root/Sources/Utilities/Constants.swift" \
    "$vault_root/Sources/Services/AuthCredentialBackend.swift" \
    "$vault_root/Scripts/Tests/AuthKeychainProbe.swift" -o "$work/Vault.app/Contents/MacOS/probe"
cp "$test_binary" "$work/CLI.app/Contents/MacOS/probe"
cp "$LPM_VAULT_PROVISIONING_PROFILE" "$work/Vault.app/Contents/embedded.provisionprofile"
cp "$LPM_CLI_PROVISIONING_PROFILE" "$work/CLI.app/Contents/embedded.provisionprofile"
codesign --force --options runtime --timestamp --entitlements "$vault_root/LPMVault.entitlements" --sign "$identity" "$work/Vault.app"
codesign --force --options runtime --timestamp --entitlements "$cli_root/macos/lpm.entitlements" --sign "$identity" "$work/CLI.app"
LPM_RUN_KEYCHAIN_TESTS=1 LPM_KEYCHAIN_INTEROP_HELPER="$work/Vault.app/Contents/MacOS/probe" \
    "$work/CLI.app/Contents/MacOS/probe" tests::macos_shared_auth_write_round_trip --ignored --exact --test-threads=1
LPM_RUN_KEYCHAIN_TESTS=1 "$work/CLI.app/Contents/MacOS/probe" \
    tests::clear_password_from_keychain_account_treats_absent_as_ok --ignored --exact --test-threads=1
