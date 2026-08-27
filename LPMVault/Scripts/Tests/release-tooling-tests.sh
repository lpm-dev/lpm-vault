#!/bin/bash
# shellcheck disable=SC1091,SC2016,SC2034
set -euo pipefail

TEST_SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd -P)"
# shellcheck source=../../release-app.sh
source "$TEST_SCRIPT_DIR/../../release-app.sh"

TEST_COUNT=0

pass() {
	TEST_COUNT=$((TEST_COUNT + 1))
}

assert_success() {
	local description="$1"
	shift
	if ! "$@"; then
		echo "FAIL: $description" >&2
		exit 1
	fi
	pass
}

assert_failure() {
	local description="$1"
	shift
	if "$@"; then
		echo "FAIL: $description" >&2
		exit 1
	fi
	pass
}

assert_equal() {
	local description="$1"
	local expected="$2"
	local actual="$3"
	if [ "$expected" != "$actual" ]; then
		echo "FAIL: $description (expected '$expected', got '$actual')" >&2
		exit 1
	fi
	pass
}

assert_success "accepts a three-component version" validate_marketing_version "1.2.3"
assert_success "accepts a two-component version" validate_marketing_version "14.0"
assert_failure "rejects a one-component marketing version" validate_marketing_version "1"
assert_failure "rejects a prerelease marketing version" validate_marketing_version "1.2.3-beta"
assert_failure "rejects leading zeroes in a version" validate_marketing_version "01.2.3"
assert_failure "rejects shell metacharacters in a version" validate_marketing_version '1.2.3;rm'

ENTITLEMENTS_FILE="$TEST_SCRIPT_DIR/../../LPMVault.entitlements"
assert_success "declares the shared LPM Keychain access group" \
	/usr/libexec/PlistBuddy -c \
	"Print :keychain-access-groups:0" "$ENTITLEMENTS_FILE"
assert_equal "uses the Team-ID-scoped LPM Keychain access group" \
	"823S8YKMRW.dev.lpm.vault.shared" \
	"$(/usr/libexec/PlistBuddy -c 'Print :keychain-access-groups:0' "$ENTITLEMENTS_FILE")"
assert_equal "uses the macOS application identifier entitlement" \
	"823S8YKMRW.dev.lpm.vault" \
	"$(/usr/libexec/PlistBuddy -c 'Print :com.apple.application-identifier' "$ENTITLEMENTS_FILE")"
assert_failure "does not grant the app sandbox entitlement" \
	/usr/libexec/PlistBuddy -c "Print :com.apple.security.app-sandbox" "$ENTITLEMENTS_FILE"
assert_failure "does not delegate vault key access to the security utility" \
	grep -Fq '/usr/bin/security' "$TEST_SCRIPT_DIR/../../Sources/Services/VaultCrypto.swift"
assert_success "builds unsigned before embedding the restricted-entitlement profile" \
	grep -Fq 'CODE_SIGNING_ALLOWED=NO' "$TEST_SCRIPT_DIR/../../release-app.sh"
assert_success "embeds the Developer ID provisioning profile" \
	grep -Fq '"$staged_app/Contents/embedded.provisionprofile"' "$TEST_SCRIPT_DIR/../../release-app.sh"
assert_success "embeds local-build profiles inside the macOS Contents directory" \
	grep -Fq '"$BUILD_DIR/$APP_NAME.app/Contents/embedded.provisionprofile"' "$TEST_SCRIPT_DIR/../../build-app.sh"
assert_success "applies entitlements during the final Developer ID signature" \
	grep -Fq -- '--entitlements "$SCRIPT_DIR/LPMVault.entitlements"' "$TEST_SCRIPT_DIR/../../release-app.sh"

assert_success "accepts an integer build" validate_build_number "42"
assert_success "accepts a three-component build" validate_build_number "42.1.9"
assert_failure "rejects a zero build" validate_build_number "0"
assert_failure "rejects leading zeroes in a build" validate_build_number "01"
assert_failure "rejects too many build components" validate_build_number "1.2.3.4"

artifact_names "2.4.6"
assert_equal "DMG artifact name" "LPM-Vault-2.4.6.dmg" "$DMG_FILENAME"
assert_equal "update ZIP artifact name" "LPM-Vault-2.4.6-macos-universal.zip" "$UPDATE_ZIP_FILENAME"

fixture_dir="$(mktemp -d)"
trap 'rm -rf -- "$fixture_dir"' EXIT

NOTARY_PROFILE="test-profile"
NOTARY_KEY_PATH=""
NOTARY_KEY_ID=""
NOTARY_ISSUER_ID=""
assert_success "accepts a Keychain notary profile" validate_notary_configuration
assert_equal "uses the Keychain profile argument" "--keychain-profile test-profile" "${NOTARY_ARGS[*]}"

NOTARY_PROFILE="test-profile"
NOTARY_KEY_PATH="/missing/key.p8"
NOTARY_KEY_ID="KEY123"
NOTARY_ISSUER_ID="00000000-0000-0000-0000-000000000000"
assert_failure "rejects mixed notary authentication modes" validate_notary_configuration

NOTARY_PROFILE=""
NOTARY_KEY_PATH=""
NOTARY_KEY_ID=""
NOTARY_ISSUER_ID=""
assert_failure "rejects missing notary authentication" validate_notary_configuration

notary_key_fixture="$fixture_dir/AuthKey_ABC123DEFG.p8"
: >"$notary_key_fixture"
NOTARY_KEY_PATH="$notary_key_fixture"
NOTARY_KEY_ID="ABC123DEFG"
NOTARY_ISSUER_ID="00000000-0000-0000-0000-000000000000"
assert_success "accepts complete API-key notary authentication" validate_notary_configuration
assert_equal "uses all API-key arguments" \
	"--key $notary_key_fixture --key-id ABC123DEFG --issuer 00000000-0000-0000-0000-000000000000" \
	"${NOTARY_ARGS[*]}"

run_silently() {
	"$@" >/dev/null 2>&1
}

run_without_notary_environment() {
	env \
		-u NOTARYTOOL_PROFILE \
		-u APPLE_NOTARY_KEY_PATH \
		-u APPLE_NOTARY_KEY_ID \
		-u APPLE_NOTARY_ISSUER_ID \
		"$@" >/dev/null 2>&1
}

assert_failure "CLI rejects an invalid version before using credentials" run_silently \
	"$TEST_SCRIPT_DIR/../../release-app.sh" --version "1" --build "1"
assert_failure "CLI rejects an unknown option" run_silently \
	"$TEST_SCRIPT_DIR/../../release-app.sh" --unknown
assert_failure "CLI rejects a release without notary authentication" run_without_notary_environment \
	"$TEST_SCRIPT_DIR/../../release-app.sh" --version "1.0.0" --build "1"

VERSION="2.4.6"
BUILD_NUMBER="17"
TEAM_ID="823S8YKMRW"
manifest="$fixture_dir/release-manifest.json"
write_release_manifest \
	"$manifest" \
	"LPM-Vault-2.4.6.dmg" "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "123" \
	"LPM-Vault-2.4.6-macos-universal.zip" "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" "456" \
	"11111111-1111-1111-1111-111111111111" "22222222-2222-2222-2222-222222222222"
assert_success "writes valid manifest JSON" jq empty "$manifest"
assert_equal "writes the manifest schema version" "1" "$(jq -r '.schemaVersion' "$manifest")"
assert_equal "writes the manifest version" "2.4.6" "$(jq -r '.version' "$manifest")"
assert_equal "writes the update artifact kind" "update-zip" "$(jq -r '.artifacts[1].kind' "$manifest")"
assert_equal "writes the app submission ID" "11111111-1111-1111-1111-111111111111" "$(jq -r '.notarization.appSubmissionId' "$manifest")"

second_manifest="$fixture_dir/release-manifest-second.json"
write_release_manifest \
	"$second_manifest" \
	"LPM-Vault-2.4.6.dmg" "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa" "123" \
	"LPM-Vault-2.4.6-macos-universal.zip" "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb" "456" \
	"11111111-1111-1111-1111-111111111111" "22222222-2222-2222-2222-222222222222"
assert_success "writes deterministic manifest content" cmp -s "$manifest" "$second_manifest"

notary_fixture="$fixture_dir/notary-result.json"
printf '%s\n' '{"id":"33333333-3333-3333-3333-333333333333","status":"Accepted"}' >"$notary_fixture"
assert_equal "reads a notary submission ID" "33333333-3333-3333-3333-333333333333" "$(notary_result_value id "$notary_fixture")"
assert_equal "reads a notary submission status" "Accepted" "$(notary_result_value status "$notary_fixture")"

help_output="$("$TEST_SCRIPT_DIR/../../release-app.sh" --help)"
assert_success "documents local-only behavior" grep -Fq "does not upload to release hosting" <<<"$help_output"

echo "Release tooling tests passed: $TEST_COUNT"
