#!/bin/bash
set -euo pipefail

# Build and package a notarized, direct-distribution release of LPM Vault.
# This script creates local artifacts only. It never publishes them or sends
# them to release hosting. Notarization necessarily submits copies to Apple.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
APP_NAME="LPM Vault"
BUNDLE_ID="dev.lpm.vault"
MINIMUM_SYSTEM_VERSION="14.0"
DEFAULT_TEAM_ID="823S8YKMRW"
DEFAULT_SIGNING_IDENTITY="Developer ID Application: Tolga Ergin (823S8YKMRW)"
EXPECTED_ACCESS_GROUP="$DEFAULT_TEAM_ID.dev.lpm.vault.shared"
EXPECTED_PROFILE_ACCESS_GROUP="$DEFAULT_TEAM_ID.*"

VERSION=""
BUILD_NUMBER=""
TEAM_ID="${LPM_TEAM_ID:-$DEFAULT_TEAM_ID}"
SIGNING_IDENTITY="${LPM_SIGNING_IDENTITY:-$DEFAULT_SIGNING_IDENTITY}"
PROVISIONING_PROFILE="${LPM_VAULT_PROVISIONING_PROFILE:-}"
NOTARY_PROFILE="${NOTARYTOOL_PROFILE:-}"
NOTARY_KEY_PATH="${APPLE_NOTARY_KEY_PATH:-}"
NOTARY_KEY_ID="${APPLE_NOTARY_KEY_ID:-}"
NOTARY_ISSUER_ID="${APPLE_NOTARY_ISSUER_ID:-}"
OUTPUT_DIR=""
WORK_DIR=""
LOG_DIR=""
NOTARY_ARGS=()
LAST_SUBMISSION_ID=""

usage() {
	cat <<'EOF'
Usage:
  ./release-app.sh --version VERSION --build BUILD [notary authentication] [options]

Required:
  --version VERSION           CFBundleShortVersionString, for example 1.0.0
  --build BUILD               CFBundleVersion, for example 1 or 42.1

Notary authentication (choose one):
  --notary-profile NAME       notarytool Keychain profile (recommended)
  --notary-key PATH           App Store Connect API private key (.p8)
  --notary-key-id ID          App Store Connect API key ID
  --notary-issuer ID          App Store Connect API issuer ID

Options:
  --identity NAME             Developer ID Application identity
  --team-id ID                Expected Apple Developer team ID
  --output-dir PATH           New directory for artifacts and logs
  -h, --help                  Show this help

Environment equivalents:
  NOTARYTOOL_PROFILE
  APPLE_NOTARY_KEY_PATH, APPLE_NOTARY_KEY_ID, APPLE_NOTARY_ISSUER_ID
  LPM_SIGNING_IDENTITY, LPM_TEAM_ID, LPM_VAULT_PROVISIONING_PROFILE

The default output directory is release/LPM-Vault-VERSION+BUILD. The target
must not already exist. The script does not upload to release hosting or create
a release. Notarization sends the app and DMG to Apple's notary service.
EOF
}

fail() {
	echo "error: $*" >&2
	exit 1
}

require_value() {
	local option="$1"
	local value="${2:-}"
	[ -n "$value" ] || fail "$option requires a value"
}

validate_marketing_version() {
	local value="${1:-}"
	[ "${#value}" -le 18 ] || return 1
	[[ "$value" =~ ^(0|[1-9][0-9]*)(\.(0|[1-9][0-9]*)){1,2}$ ]]
}

validate_build_number() {
	local value="${1:-}"
	[ "${#value}" -le 18 ] || return 1
	[[ "$value" =~ ^[1-9][0-9]{0,3}(\.(0|[1-9][0-9]?)){0,2}$ ]]
}

validate_team_id() {
	[[ "${1:-}" =~ ^[A-Z0-9]{10}$ ]]
}

validate_notary_configuration() {
	local has_profile=0
	local key_fields=0

	[ -z "$NOTARY_PROFILE" ] || has_profile=1
	[ -z "$NOTARY_KEY_PATH" ] || key_fields=$((key_fields + 1))
	[ -z "$NOTARY_KEY_ID" ] || key_fields=$((key_fields + 1))
	[ -z "$NOTARY_ISSUER_ID" ] || key_fields=$((key_fields + 1))

	if [ "$has_profile" -eq 1 ] && [ "$key_fields" -ne 0 ]; then
		return 1
	fi
	if [ "$has_profile" -eq 0 ] && [ "$key_fields" -ne 3 ]; then
		return 1
	fi
	if [ "$has_profile" -eq 1 ]; then
		[[ "$NOTARY_PROFILE" != *$'\n'* ]] || return 1
		NOTARY_ARGS=(--keychain-profile "$NOTARY_PROFILE")
	else
		[ -f "$NOTARY_KEY_PATH" ] || return 1
		[[ "$NOTARY_KEY_ID" =~ ^[A-Z0-9]{10}$ ]] || return 1
		[[ "$NOTARY_ISSUER_ID" =~ ^[A-Fa-f0-9]{8}(-[A-Fa-f0-9]{4}){3}-[A-Fa-f0-9]{12}$ ]] || return 1
		NOTARY_ARGS=(--key "$NOTARY_KEY_PATH" --key-id "$NOTARY_KEY_ID" --issuer "$NOTARY_ISSUER_ID")
	fi
}

artifact_names() {
	local version="$1"
	ARTIFACT_STEM="LPM-Vault-$version"
	DMG_FILENAME="$ARTIFACT_STEM.dmg"
	UPDATE_ZIP_FILENAME="$ARTIFACT_STEM-macos-universal.zip"
}

parse_arguments() {
	while [ "$#" -gt 0 ]; do
		case "$1" in
			--version)
				require_value "$1" "${2:-}"
				VERSION="$2"
				shift 2
				;;
			--build)
				require_value "$1" "${2:-}"
				BUILD_NUMBER="$2"
				shift 2
				;;
			--identity)
				require_value "$1" "${2:-}"
				SIGNING_IDENTITY="$2"
				shift 2
				;;
			--team-id)
				require_value "$1" "${2:-}"
				TEAM_ID="$2"
				shift 2
				;;
			--notary-profile)
				require_value "$1" "${2:-}"
				NOTARY_PROFILE="$2"
				shift 2
				;;
			--notary-key)
				require_value "$1" "${2:-}"
				NOTARY_KEY_PATH="$2"
				shift 2
				;;
			--notary-key-id)
				require_value "$1" "${2:-}"
				NOTARY_KEY_ID="$2"
				shift 2
				;;
			--notary-issuer)
				require_value "$1" "${2:-}"
				NOTARY_ISSUER_ID="$2"
				shift 2
				;;
			--output-dir)
				require_value "$1" "${2:-}"
				OUTPUT_DIR="$2"
				shift 2
				;;
			-h|--help)
				usage
				exit 0
				;;
			*)
				fail "unknown option: $1"
				;;
		esac
	done
}

validate_arguments() {
	[ -n "$VERSION" ] || fail "--version is required"
	[ -n "$BUILD_NUMBER" ] || fail "--build is required"
	validate_marketing_version "$VERSION" || fail "invalid version '$VERSION' (use two or three numeric components)"
	validate_build_number "$BUILD_NUMBER" || fail "invalid build '$BUILD_NUMBER' (use one to three numeric components)"
	validate_team_id "$TEAM_ID" || fail "invalid team ID '$TEAM_ID'"
	[ "$TEAM_ID" = "$DEFAULT_TEAM_ID" ] || fail "the shared Keychain group requires Apple team $DEFAULT_TEAM_ID"
	[ -n "$SIGNING_IDENTITY" ] || fail "the signing identity cannot be empty"
	[ -f "$PROVISIONING_PROFILE" ] || fail "set LPM_VAULT_PROVISIONING_PROFILE to the Developer ID profile for $BUNDLE_ID"
	validate_notary_configuration || fail "configure either a notarytool Keychain profile or all three API-key options"
}

require_tools() {
	local tool
	for tool in xcodebuild xcrun security codesign spctl lipo hdiutil ditto shasum stat jq python3; do
		command -v "$tool" >/dev/null 2>&1 || fail "required tool is unavailable: $tool"
	done
	[ -x /usr/libexec/PlistBuddy ] || fail "required tool is unavailable: /usr/libexec/PlistBuddy"
}

prepare_output_directory() {
	local parent base
	if [ -z "$OUTPUT_DIR" ]; then
		OUTPUT_DIR="$SCRIPT_DIR/release/LPM-Vault-$VERSION+$BUILD_NUMBER"
	fi
	case "$OUTPUT_DIR" in
		/|.|..)
			fail "unsafe output directory: $OUTPUT_DIR"
			;;
	esac
	[ ! -e "$OUTPUT_DIR" ] || fail "output directory already exists: $OUTPUT_DIR"
	parent="$(dirname "$OUTPUT_DIR")"
	base="$(basename "$OUTPUT_DIR")"
	[ -n "$base" ] && [ "$base" != "." ] && [ "$base" != ".." ] || fail "invalid output directory"
	mkdir -p "$parent"
	parent="$(cd "$parent" && pwd -P)"
	OUTPUT_DIR="$parent/$base"
	mkdir "$OUTPUT_DIR"
	LOG_DIR="$OUTPUT_DIR/logs"
	mkdir "$LOG_DIR"
	WORK_DIR="$(mktemp -d "$OUTPUT_DIR/.work.XXXXXX")"
}

cleanup() {
	local status=$?
	if [ -n "$WORK_DIR" ] && [ -d "$WORK_DIR" ]; then
		case "$WORK_DIR" in
			"$OUTPUT_DIR"/.work.*)
				rm -rf -- "$WORK_DIR"
				;;
		esac
	fi
	if [ "$status" -ne 0 ] && [ -n "$OUTPUT_DIR" ] && [ -d "$OUTPUT_DIR" ]; then
		echo "Release failed. Diagnostic logs are in: $LOG_DIR" >&2
	fi
	return "$status"
}

check_signing_identity() {
	if ! security find-identity -v -p codesigning | grep -Fq -- "\"$SIGNING_IDENTITY\""; then
		fail "Developer ID identity is not available in the current Keychain: $SIGNING_IDENTITY"
	fi
}

check_provisioning_profile() {
	local profile_plist="$LOG_DIR/provisioning-profile.plist"
	local profile_team_id profile_application_id profile_access_groups
	security cms -D -i "$PROVISIONING_PROFILE" >"$profile_plist"
	profile_team_id="$(/usr/libexec/PlistBuddy -c 'Print :TeamIdentifier:0' "$profile_plist")"
	profile_application_id="$(
		/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.application-identifier' "$profile_plist" 2>/dev/null ||
			/usr/libexec/PlistBuddy -c 'Print :Entitlements:application-identifier' "$profile_plist"
	)"
	profile_access_groups="$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:keychain-access-groups' "$profile_plist")"
	[ "$profile_team_id" = "$TEAM_ID" ] || fail "provisioning profile has the wrong team"
	[ "$profile_application_id" = "$TEAM_ID.$BUNDLE_ID" ] || fail "provisioning profile has the wrong application identifier"
	printf '%s\n' "$profile_access_groups" | awk \
		-v exact="$EXPECTED_ACCESS_GROUP" \
		-v wildcard="$EXPECTED_PROFILE_ACCESS_GROUP" \
		'{ value = $0; gsub(/^[[:space:]]+|[[:space:]]+$/, "", value); if (value == exact || value == wildcard) found = 1 } END { exit(found ? 0 : 1) }' || \
		fail "provisioning profile does not authorize the shared Keychain group"
}

check_notary_authentication() {
	local output_file="$LOG_DIR/notary-auth-check.json"
	local error_file="$LOG_DIR/notary-auth-check.stderr.log"
	echo "Checking notary authentication..."
	if ! xcrun notarytool history "${NOTARY_ARGS[@]}" --output-format json >"$output_file" 2>"$error_file"; then
		cat "$error_file" >&2
		fail "notarytool authentication failed"
	fi
}

build_signed_app() {
	local derived_data="$WORK_DIR/DerivedData"
	local build_log="$LOG_DIR/xcodebuild.log"
	local built_app="$derived_data/Build/Products/Release/$APP_NAME.app"
	local staged_app="$WORK_DIR/$APP_NAME.app"

	echo "Building clean universal Release app..."
	if ! xcodebuild \
		-project "$SCRIPT_DIR/LPMVault.xcodeproj" \
		-scheme LPMVault \
		-configuration Release \
		-destination 'generic/platform=macOS' \
		-derivedDataPath "$derived_data" \
		clean build \
		ARCHS='arm64 x86_64' \
		ONLY_ACTIVE_ARCH=NO \
		MARKETING_VERSION="$VERSION" \
		CURRENT_PROJECT_VERSION="$BUILD_NUMBER" \
		CODE_SIGNING_ALLOWED=NO \
		CODE_SIGNING_REQUIRED=NO >"$build_log" 2>&1; then
		grep -E '(^|[[:space:]])(error:|warning:)|BUILD FAILED' "$build_log" >&2 || tail -80 "$build_log" >&2
		fail "xcodebuild failed; see $build_log"
	fi
	[ -d "$built_app" ] || fail "xcodebuild completed without producing $built_app"
	if grep -Eq '(^|[[:space:]])warning:' "$build_log"; then
		fail "release build contains warnings; see $build_log"
	fi
	ditto "$built_app" "$staged_app"
	cp "$PROVISIONING_PROFILE" "$staged_app/Contents/embedded.provisionprofile"
	bash "$SCRIPT_DIR/Scripts/sign-sparkle.sh" "$staged_app" "$SIGNING_IDENTITY" --timestamp
	codesign --force --timestamp --options runtime \
		--entitlements "$SCRIPT_DIR/LPMVault.entitlements" \
		--sign "$SIGNING_IDENTITY" \
		"$staged_app"
	SIGNED_APP="$staged_app"
}

plist_value() {
	/usr/libexec/PlistBuddy -c "Print :$2" "$1/Contents/Info.plist"
}

verify_signed_app() {
	local app_path="$1"
	local verify_log="$LOG_DIR/app-signature-verification.log"
	local details entitlements architectures normalized_architectures

	echo "Verifying Developer ID signature and release metadata..."
	if ! codesign --verify --deep --strict --verbose=2 "$app_path" >"$verify_log" 2>&1; then
		cat "$verify_log" >&2
		fail "the app signature is invalid"
	fi
	details="$(codesign -d --verbose=4 "$app_path" 2>&1)"
	printf '%s\n' "$details" >>"$verify_log"
	grep -Fq "Identifier=$BUNDLE_ID" <<<"$details" || fail "signed app has the wrong bundle identifier"
	grep -Fq "TeamIdentifier=$TEAM_ID" <<<"$details" || fail "signed app has the wrong Apple team identifier"
	grep -Fq "Authority=$SIGNING_IDENTITY" <<<"$details" || fail "signed app has the wrong signing authority"
	grep -Eq 'flags=.*\(.*runtime.*\)' <<<"$details" || fail "signed app is missing the hardened runtime"
	grep -Fq 'Timestamp=' <<<"$details" || fail "signed app is missing a secure timestamp"
	if grep -Fq 'Signature=adhoc' <<<"$details"; then
		fail "signed app still has an ad-hoc signature"
	fi

	[ "$(plist_value "$app_path" CFBundleIdentifier)" = "$BUNDLE_ID" ] || fail "Info.plist has the wrong bundle identifier"
	[ "$(plist_value "$app_path" CFBundleShortVersionString)" = "$VERSION" ] || fail "Info.plist has the wrong version"
	[ "$(plist_value "$app_path" CFBundleVersion)" = "$BUILD_NUMBER" ] || fail "Info.plist has the wrong build number"
	[ "$(plist_value "$app_path" LSMinimumSystemVersion)" = "$MINIMUM_SYSTEM_VERSION" ] || fail "Info.plist has the wrong minimum macOS version"
	python3 "$SCRIPT_DIR/Scripts/verify-update-config.py" "$app_path/Contents/Info.plist"
	local component component_entitlements
	for component in \
		"Versions/B/XPCServices/Downloader.xpc" \
		"Versions/B/XPCServices/Installer.xpc" \
		"Versions/B/Autoupdate" "Versions/B/Updater.app" "."; do
		component_entitlements="$(codesign -d --entitlements - "$app_path/Contents/Frameworks/Sparkle.framework/$component" 2>/dev/null)"
		if grep -Eq 'keychain-access-groups|com.apple.security.get-task-allow' <<<"$component_entitlements"; then
			fail "Sparkle component has prohibited entitlements: $component"
		fi
	done

	architectures="$(lipo -archs "$app_path/Contents/MacOS/$APP_NAME")"
	normalized_architectures="$(printf '%s\n' "$architectures" | tr ' ' '\n' | LC_ALL=C sort | paste -sd ' ' -)"
	[ "$normalized_architectures" = "arm64 x86_64" ] || fail "expected arm64 and x86_64, found: $architectures"

	entitlements="$(codesign -d --entitlements :- "$app_path" 2>/dev/null || true)"
	printf '%s\n' "$entitlements" >"$LOG_DIR/app-entitlements.plist"
	[ "$(/usr/libexec/PlistBuddy -c 'Print :keychain-access-groups:0' "$LOG_DIR/app-entitlements.plist")" = "$EXPECTED_ACCESS_GROUP" ] \
		|| fail "release signature is missing the shared Keychain access group"
	if grep -Eq 'com\.apple\.security\.(get-task-allow|app-sandbox)' <<<"$entitlements"; then
		fail "release signature contains a prohibited debug or sandbox entitlement"
	fi
}

notary_result_value() {
	local key="$1"
	local result_file="$2"
	jq -r --arg key "$key" '.[$key] // empty' "$result_file" 2>/dev/null || true
}

fetch_notary_log() {
	local submission_id="$1"
	local label="$2"
	[ -n "$submission_id" ] || return 0
	xcrun notarytool log "$submission_id" "${NOTARY_ARGS[@]}" \
		--output-format json >"$LOG_DIR/notarization-$label-log.json" \
		2>"$LOG_DIR/notarization-$label-log.stderr.log" || true
}

submit_for_notarization() {
	local artifact="$1"
	local label="$2"
	local result_file="$LOG_DIR/notarization-$label.json"
	local error_file="$LOG_DIR/notarization-$label.stderr.log"
	local status submission_id

	echo "Submitting $label for notarization..."
	if ! xcrun notarytool submit "$artifact" "${NOTARY_ARGS[@]}" \
		--wait --output-format json >"$result_file" 2>"$error_file"; then
		submission_id="$(notary_result_value id "$result_file")"
		fetch_notary_log "$submission_id" "$label"
		cat "$error_file" >&2
		fail "notarization submission failed for $label${submission_id:+ (submission $submission_id)}"
	fi

	submission_id="$(notary_result_value id "$result_file")"
	status="$(notary_result_value status "$result_file")"
	if [ "$status" != "Accepted" ]; then
		fetch_notary_log "$submission_id" "$label"
		fail "notarization was not accepted for $label${submission_id:+ (submission $submission_id)}; status: ${status:-unknown}"
	fi
	[ -n "$submission_id" ] || fail "notarytool accepted $label but returned no submission ID"
	LAST_SUBMISSION_ID="$submission_id"
}

staple_and_validate() {
	local path="$1"
	local label="$2"
	xcrun stapler staple -v "$path" >"$LOG_DIR/stapler-$label.log" 2>&1 || {
		cat "$LOG_DIR/stapler-$label.log" >&2
		fail "could not staple notarization ticket to $label"
	}
	xcrun stapler validate -v "$path" >>"$LOG_DIR/stapler-$label.log" 2>&1 || {
		cat "$LOG_DIR/stapler-$label.log" >&2
		fail "the stapled notarization ticket is invalid for $label"
	}
}

verify_gatekeeper_app() {
	local app_path="$1"
	local log_file="$LOG_DIR/gatekeeper-app.log"
	if ! spctl --assess --type execute --verbose=4 "$app_path" >"$log_file" 2>&1; then
		cat "$log_file" >&2
		fail "Gatekeeper rejected the notarized app"
	fi
}

create_update_zip() {
	local app_path="$1"
	local destination="$2"
	echo "Creating universal update ZIP..."
	ditto -c -k --sequesterRsrc --keepParent "$app_path" "$destination"
}

verify_update_zip() {
	local archive="$1"
	local extracted_dir="$WORK_DIR/update-zip-verification"
	local extracted_app="$extracted_dir/$APP_NAME.app"
	local signature_log="$LOG_DIR/update-zip-signature-verification.log"
	local ticket_log="$LOG_DIR/update-zip-ticket-verification.log"

	mkdir "$extracted_dir"
	ditto -x -k "$archive" "$extracted_dir"
	[ -d "$extracted_app" ] || fail "the update ZIP does not contain $APP_NAME.app at its root"
	if ! codesign --verify --deep --strict --verbose=2 "$extracted_app" >"$signature_log" 2>&1; then
		cat "$signature_log" >&2
		fail "the update ZIP did not preserve the app signature"
	fi
	if ! xcrun stapler validate -v "$extracted_app" >"$ticket_log" 2>&1; then
		cat "$ticket_log" >&2
		fail "the update ZIP did not preserve the app notarization ticket"
	fi
}

verify_signed_dmg() {
	local dmg_path="$1"
	local verify_log="$LOG_DIR/dmg-signature-verification.log"
	local details

	if ! codesign --verify --strict --verbose=2 "$dmg_path" >"$verify_log" 2>&1; then
		cat "$verify_log" >&2
		fail "the DMG signature is invalid"
	fi
	details="$(codesign -d --verbose=4 "$dmg_path" 2>&1)"
	printf '%s\n' "$details" >>"$verify_log"
	grep -Fq "TeamIdentifier=$TEAM_ID" <<<"$details" || fail "signed DMG has the wrong Apple team identifier"
	grep -Fq "Authority=$SIGNING_IDENTITY" <<<"$details" || fail "signed DMG has the wrong signing authority"
	grep -Fq 'Timestamp=' <<<"$details" || fail "signed DMG is missing a secure timestamp"
}

create_dmg() {
	local app_path="$1"
	local destination="$2"
	local dmg_source="$WORK_DIR/dmg-source"
	local dmg_log="$LOG_DIR/hdiutil.log"

	echo "Creating signed DMG..."
	mkdir "$dmg_source"
	ditto "$app_path" "$dmg_source/$APP_NAME.app"
	ln -s /Applications "$dmg_source/Applications"
	if ! hdiutil create \
		-volname "$APP_NAME" \
		-srcfolder "$dmg_source" \
		-format UDZO \
		-fs HFS+ \
		-nospotlight \
		"$destination" >"$dmg_log" 2>&1; then
		cat "$dmg_log" >&2
		fail "could not create the DMG"
	fi
	codesign --force --sign "$SIGNING_IDENTITY" --timestamp "$destination"
	verify_signed_dmg "$destination"
}

verify_gatekeeper_dmg() {
	local dmg_path="$1"
	local log_file="$LOG_DIR/gatekeeper-dmg.log"
	if ! spctl --assess --type open --context context:primary-signature --verbose=4 "$dmg_path" >"$log_file" 2>&1; then
		cat "$log_file" >&2
		fail "Gatekeeper rejected the notarized DMG"
	fi
}

sha256_file() {
	shasum -a 256 "$1" | awk '{print $1}'
}

file_size() {
	stat -f '%z' "$1"
}

write_release_manifest() {
	local destination="$1"
	local dmg_name="$2"
	local dmg_sha="$3"
	local dmg_size="$4"
	local zip_name="$5"
	local zip_sha="$6"
	local zip_size="$7"
	local app_submission_id="$8"
	local dmg_submission_id="$9"

	cat >"$destination" <<EOF
{
  "schemaVersion": 1,
  "product": "$APP_NAME",
  "bundleIdentifier": "$BUNDLE_ID",
  "version": "$VERSION",
  "build": "$BUILD_NUMBER",
  "minimumSystemVersion": "$MINIMUM_SYSTEM_VERSION",
  "architectures": [
    "arm64",
    "x86_64"
  ],
  "teamIdentifier": "$TEAM_ID",
  "notarization": {
    "appSubmissionId": "$app_submission_id",
    "dmgSubmissionId": "$dmg_submission_id"
  },
  "artifacts": [
    {
      "kind": "dmg",
      "file": "$dmg_name",
      "sha256": "$dmg_sha",
      "size": $dmg_size
    },
    {
      "kind": "update-zip",
      "file": "$zip_name",
      "sha256": "$zip_sha",
      "size": $zip_size
    }
  ]
}
EOF
	jq empty "$destination"
}

write_checksums_and_manifest() {
	local dmg_path="$1"
	local zip_path="$2"
	local app_submission_id="$3"
	local dmg_submission_id="$4"
	local dmg_sha zip_sha dmg_size zip_size

	dmg_sha="$(sha256_file "$dmg_path")"
	zip_sha="$(sha256_file "$zip_path")"
	dmg_size="$(file_size "$dmg_path")"
	zip_size="$(file_size "$zip_path")"
	printf '%s  %s\n%s  %s\n' \
		"$dmg_sha" "$(basename "$dmg_path")" \
		"$zip_sha" "$(basename "$zip_path")" >"$OUTPUT_DIR/checksums.txt"
	write_release_manifest \
		"$OUTPUT_DIR/release-manifest.json" \
		"$(basename "$dmg_path")" "$dmg_sha" "$dmg_size" \
		"$(basename "$zip_path")" "$zip_sha" "$zip_size" \
		"$app_submission_id" "$dmg_submission_id"
}

main() {
	local app_notary_zip app_submission_id dmg_submission_id dmg_path update_zip_path

	parse_arguments "$@"
	validate_arguments
	require_tools
	artifact_names "$VERSION"
	prepare_output_directory
	trap cleanup EXIT
	check_signing_identity
	check_provisioning_profile
	check_notary_authentication
	build_signed_app
	verify_signed_app "$SIGNED_APP"

	app_notary_zip="$WORK_DIR/LPM-Vault-app-notarization.zip"
	ditto -c -k --sequesterRsrc --keepParent "$SIGNED_APP" "$app_notary_zip"
	submit_for_notarization "$app_notary_zip" app
	app_submission_id="$LAST_SUBMISSION_ID"
	staple_and_validate "$SIGNED_APP" app
	verify_gatekeeper_app "$SIGNED_APP"

	update_zip_path="$OUTPUT_DIR/$UPDATE_ZIP_FILENAME"
	create_update_zip "$SIGNED_APP" "$update_zip_path"
	verify_update_zip "$update_zip_path"
	dmg_path="$OUTPUT_DIR/$DMG_FILENAME"
	create_dmg "$SIGNED_APP" "$dmg_path"
	submit_for_notarization "$dmg_path" dmg
	dmg_submission_id="$LAST_SUBMISSION_ID"
	staple_and_validate "$dmg_path" dmg
	verify_gatekeeper_dmg "$dmg_path"
	write_checksums_and_manifest "$dmg_path" "$update_zip_path" "$app_submission_id" "$dmg_submission_id"

	echo "Release artifacts are ready: $OUTPUT_DIR"
	echo "No artifacts were uploaded to release hosting or published."
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
	main "$@"
fi
