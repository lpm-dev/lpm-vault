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

# Fake codesign and xcrun go first on PATH. Each call appends its quoted
# arguments to $FAKE_TOOL_DIR/<tool>.calls and consumes the next "status|output"
# line queued in <tool>.outcomes, printing the output to stdout on success and
# to stderr on failure. A call with nothing queued fails the test run.
fake_bin="$fixture_dir/bin"
FAKE_TOOL_DIR="$fixture_dir/fake-tools"
export FAKE_TOOL_DIR
mkdir "$fake_bin" "$FAKE_TOOL_DIR"
for tool in codesign xcrun; do
	cat >"$fake_bin/$tool" <<'EOF'
#!/bin/bash
set -euo pipefail
tool="$(basename "$0")"
printf '%q ' "$@" >>"$FAKE_TOOL_DIR/$tool.calls"
printf '\n' >>"$FAKE_TOOL_DIR/$tool.calls"
queue="$FAKE_TOOL_DIR/$tool.outcomes"
outcome="$(head -n 1 "$queue")"
[ -n "$outcome" ] || { echo "fake $tool: unexpected call: $*" >&2; exit 99; }
tail -n +2 "$queue" >"$queue.rest"
mv "$queue.rest" "$queue"
status="${outcome%%|*}"
if [ "$status" -eq 0 ]; then
	printf '%s\n' "${outcome#*|}"
else
	printf '%s\n' "${outcome#*|}" >&2
fi
exit "$status"
EOF
	chmod +x "$fake_bin/$tool"
done

export LPM_APPLE_SERVICE_BACKOFF_SECONDS=0
APPLE_SERVICE_BACKOFF_SECONDS=0
NOTARY_STATUS_INTERVAL_SECONDS=0

lines() {
	printf '%s\n' "$@"
}

# Runs a command in a subshell with the fakes, recording its exit status in
# FAKE_STATUS and its output in $FAKE_TOOL_DIR/stdout and stderr.
run_with_fakes() {
	local xcrun_outcomes="$1"
	local codesign_outcomes="$2"
	shift 2
	rm -f -- "$FAKE_TOOL_DIR"/*
	printf '%s' "$xcrun_outcomes" >"$FAKE_TOOL_DIR/xcrun.outcomes"
	printf '%s' "$codesign_outcomes" >"$FAKE_TOOL_DIR/codesign.outcomes"
	: >"$FAKE_TOOL_DIR/xcrun.calls"
	: >"$FAKE_TOOL_DIR/codesign.calls"
	set +e
	(
		set -e
		PATH="$fake_bin:$PATH"
		"$@"
	) >"$FAKE_TOOL_DIR/stdout" 2>"$FAKE_TOOL_DIR/stderr"
	FAKE_STATUS=$?
	set -e
}

call_count() {
	wc -l <"$FAKE_TOOL_DIR/$1.calls" | tr -d ' '
}

call() {
	sed -n "${2}p" "$FAKE_TOOL_DIR/$1.calls"
}

quoted() {
	printf '%q ' "$@"
}

LOG_DIR="$fixture_dir/logs"
mkdir "$LOG_DIR"
cloudkit_dropped='The network connection was lost. The staple and validate action failed! Error 68.'

stapled_app="$fixture_dir/stapled/LPM Vault.app"
mkdir -p "$stapled_app"
run_with_fakes "$(lines "68|$cloudkit_dropped" '0|The staple and validate action worked!' '0|The validate action worked!')" "" \
	staple_and_validate "$stapled_app" app
assert_equal "staples the app after the ticketing service drops a connection" "0" "$FAKE_STATUS"
assert_equal "staples again only after the dropped connection, then validates" "3" "$(call_count xcrun)"
assert_equal "staples the same app again" "$(quoted stapler staple -v "$stapled_app")" "$(call xcrun 2)"
assert_equal "validates the stapled app" "$(quoted stapler validate -v "$stapled_app")" "$(call xcrun 3)"
assert_success "reports the retry in the release output" grep -Fq '::warning::stapler staple hit a transient Apple service failure' "$FAKE_TOOL_DIR/stderr"

run_with_fakes "$(lines '65|The staple and validate action failed! Error 65.' '0|')" "" \
	staple_and_validate "$stapled_app" app
assert_failure "fails when the ticket is invalid" [ "$FAKE_STATUS" -eq 0 ]
assert_equal "doesn't staple again when the ticket is invalid" "1" "$(call_count xcrun)"

update_source="$fixture_dir/update-source/$APP_NAME.app"
mkdir -p "$update_source/Contents"
update_zip="$fixture_dir/update.zip"
ditto -c -k --keepParent "$update_source" "$update_zip"
WORK_DIR="$fixture_dir/work-update-zip"
mkdir "$WORK_DIR"
run_with_fakes "$(lines "68|$cloudkit_dropped" '0|The validate action worked!')" "$(lines '0|')" \
	verify_update_zip "$update_zip"
assert_equal "validates the update ZIP's ticket after the ticketing service drops a connection" "0" "$FAKE_STATUS"
assert_equal "validates the update ZIP's ticket again only after the dropped connection" "2" "$(call_count xcrun)"

NOTARY_ARGS=(--keychain-profile test-profile)
notary_input="$fixture_dir/LPM Vault notarization.zip"
: >"$notary_input"
submission="44444444-4444-4444-4444-444444444444"
submitted="{\"id\":\"$submission\",\"message\":\"Successfully uploaded file\"}"
in_progress="{\"id\":\"$submission\",\"status\":\"In Progress\"}"
accepted="{\"id\":\"$submission\",\"status\":\"Accepted\"}"
invalid="{\"id\":\"$submission\",\"status\":\"Invalid\"}"
withdrawn="{\"id\":\"$submission\",\"status\":\"Withdrawn\"}"
network_lost='Error: Error Domain=NSURLErrorDomain Code=-1005 "The network connection was lost."'
timed_out='Error: Error Domain=NSURLErrorDomain Code=-1001 "The request timed out."'

notarize_and_report() {
	submit_for_notarization "$@"
	echo "submission=$LAST_SUBMISSION_ID"
}

run_with_fakes "$(lines "1|$network_lost" "0|$submitted" "1|$timed_out" \
	"0|$in_progress" \
	"0|$accepted")" "" \
	notarize_and_report "$notary_input" app
assert_equal "notarizes through a lost upload and a failed status check" "0" "$FAKE_STATUS"
assert_success "reports the accepted submission" grep -Fxq "submission=$submission" "$FAKE_TOOL_DIR/stdout"
assert_equal "uploads again only after the lost upload, then checks status until accepted" "5" "$(call_count xcrun)"
assert_equal "uploads the same artifact again" \
	"$(quoted notarytool submit "$notary_input" --keychain-profile test-profile --output-format json)" "$(call xcrun 2)"
assert_equal "checks the submission it uploaded" \
	"$(quoted notarytool info "$submission" --keychain-profile test-profile --output-format json)" "$(call xcrun 5)"
assert_failure "never waits inside one notarytool connection" grep -Fq -- '--wait' "$FAKE_TOOL_DIR/xcrun.calls"

run_with_fakes "$(lines "0|$submitted" "0|$invalid" '0|{"issues":[]}')" "" \
	notarize_and_report "$notary_input" app
assert_failure "fails when Apple rejects the artifact" [ "$FAKE_STATUS" -eq 0 ]
assert_equal "fetches the notary log once Apple rejects the artifact, without uploading again" "3" "$(call_count xcrun)"
assert_equal "fetches the rejected submission's log" \
	"$(quoted notarytool log "$submission" --keychain-profile test-profile --output-format json)" "$(call xcrun 3)"

run_with_fakes "$(lines "0|$submitted" "0|$withdrawn")" "" \
	notarize_and_report "$notary_input" app
assert_failure "fails on a status notarytool doesn't document" [ "$FAKE_STATUS" -eq 0 ]
assert_equal "stops checking at a status notarytool doesn't document" "2" "$(call_count xcrun)"

run_with_fakes "$(lines "1|$network_lost" "1|$network_lost" "1|$network_lost" "1|$network_lost" "0|$submitted")" "" \
	notarize_and_report "$notary_input" app
assert_failure "gives up when every upload is lost" [ "$FAKE_STATUS" -eq 0 ]
assert_equal "uploads at most four times" "4" "$(call_count xcrun)"

saved_status_checks="$NOTARY_STATUS_CHECKS"
NOTARY_STATUS_CHECKS=3
run_with_fakes "$(lines "0|$submitted" "1|$timed_out" "0|$in_progress" "1|$timed_out" \
	"0|$accepted")" "" \
	notarize_and_report "$notary_input" app
NOTARY_STATUS_CHECKS="$saved_status_checks"
assert_failure "gives up when Apple decides nothing within the status-check budget" [ "$FAKE_STATUS" -eq 0 ]
assert_equal "checks status at most the budgeted number of times" "4" "$(call_count xcrun)"
assert_success "names the submission it gave up on" grep -Fq "$submission" "$FAKE_TOOL_DIR/stderr"

run_with_fakes "$(lines "1|$network_lost" '0|{"history":[]}')" "" check_notary_authentication
assert_equal "authenticates with the notary service after a dropped connection" "0" "$FAKE_STATUS"
assert_equal "checks authentication again only after the dropped connection" "2" "$(call_count xcrun)"

rejected_key='Error: HTTP status code: 401. Unable to authenticate.'
run_with_fakes "$(lines "1|$rejected_key" "1|$rejected_key" "1|$rejected_key" '0|{"history":[]}')" "" check_notary_authentication
assert_failure "fails when the notary service keeps rejecting authentication" [ "$FAKE_STATUS" -eq 0 ]
assert_equal "checks authentication at most three times" "3" "$(call_count xcrun)"

sparkle_app="$fixture_dir/sparkle/LPM Vault.app"
sparkle_framework="$sparkle_app/Contents/Frameworks/Sparkle.framework"
mkdir -p "$sparkle_framework/Versions/B/XPCServices/Downloader.xpc" \
	"$sparkle_framework/Versions/B/XPCServices/Installer.xpc" \
	"$sparkle_framework/Versions/B/Updater.app"
: >"$sparkle_framework/Versions/B/Autoupdate"
sparkle_identity="Developer ID Application: Example (TEAMID1234)"
run_with_fakes "" "$(lines '1|Downloader.xpc: The timestamp service is not available.' '0|' '0|' '0|' '0|' '0|')" \
	bash "$TEST_SCRIPT_DIR/../sign-sparkle.sh" "$sparkle_app" "$sparkle_identity" --timestamp
assert_equal "signs Sparkle after the timestamp authority fails once" "0" "$FAKE_STATUS"
assert_equal "signs the component the authority failed again, then the rest" "6" "$(call_count codesign)"
assert_equal "signs the same component again" "$(call codesign 1)" "$(call codesign 2)"

assert_failure "signs with a timestamp only through the Apple service retry" \
	grep -Eq '^[[:space:]]*(if ! )?codesign [^#]*--timestamp' "$TEST_SCRIPT_DIR/../../release-app.sh"
assert_failure "staples and validates tickets only through the Apple service retry" \
	grep -Eq '^[[:space:]]*(if ! )?xcrun stapler' "$TEST_SCRIPT_DIR/../../release-app.sh"
assert_failure "signs Sparkle only through the Apple service retry" \
	grep -Eq '^[[:space:]]*codesign ' "$TEST_SCRIPT_DIR/../sign-sparkle.sh"

retry="$TEST_SCRIPT_DIR/../with-apple-service-retry.sh"
retry_bundle="$fixture_dir/signed bundle/LPM Vault.app"
codesign_arguments=(--force --timestamp --options runtime --sign "$sparkle_identity" "$retry_bundle")
transient_timestamp_failures=(
	"A timestamp was expected but was not found."
	"The timestamp service is not available."
	"The time source for the Timestamp Authority is not available."
	"The timestamp request cannot be handled due to system failure."
	"A timestamp transaction is waiting."
	"A timestamp transaction was rejected."
)
codesign_outcomes=()
for failure in "${transient_timestamp_failures[@]}"; do
	codesign_outcomes+=("1|$retry_bundle: $failure")
done
LPM_APPLE_SERVICE_MAX_ATTEMPTS=7 run_with_fakes "" "$(lines "${codesign_outcomes[@]}" '0|signed')" \
	bash "$retry" codesign "${codesign_arguments[@]}"
assert_equal "codesign recovers from every transient timestamp failure" "0" "$FAKE_STATUS"
assert_equal "codesign runs again after each transient timestamp failure" "7" "$(call_count codesign)"
assert_equal "codesign keeps its arguments on every attempt" "1" "$(sort -u "$FAKE_TOOL_DIR/codesign.calls" | wc -l | tr -d ' ')"
assert_equal "codesign keeps its arguments" "$(quoted "${codesign_arguments[@]}")" "$(call codesign 7)"
assert_success "passes codesign's own failure through" grep -Fq "$retry_bundle: A timestamp was expected but was not found." "$FAKE_TOOL_DIR/stderr"
assert_equal "announces each codesign retry" "6" "$(grep -c '^::warning::codesign hit a transient Apple service failure' "$FAKE_TOOL_DIR/stderr")"

for failure in \
	"no identity found" \
	"The requested policy is not supported by the Timestamp Authority." \
	"An unrecognized or unsupported Algorithm Identifier in timestamp." \
	"The timestamp was not trusted." \
	"The timestamp was not valid."; do
	run_with_fakes "" "$(lines "1|$retry_bundle: $failure" '0|signed')" bash "$retry" codesign "${codesign_arguments[@]}"
	assert_equal "codesign fails with its own status on '$failure'" "1" "$FAKE_STATUS"
	assert_equal "codesign doesn't retry '$failure'" "1" "$(call_count codesign)"
done

missing_bundle="$fixture_dir/timestamp-input/Missing.app"
run_with_fakes "" "$(lines '1|No such file or directory' '0|signed')" bash "$retry" codesign --force --timestamp "$missing_bundle"
assert_equal "codesign doesn't mistake a path naming the timestamp for an outage" "1" "$(call_count codesign)"

LPM_APPLE_SERVICE_MAX_ATTEMPTS=3 run_with_fakes "" \
	"$(lines "${codesign_outcomes[0]}" "${codesign_outcomes[0]}" "${codesign_outcomes[0]}" '0|signed')" \
	bash "$retry" codesign "${codesign_arguments[@]}"
assert_equal "codesign gives up with its own status after the attempt budget" "1" "$FAKE_STATUS"
assert_equal "codesign runs at most the attempt budget" "3" "$(call_count codesign)"
assert_success "reports a lasting timestamp outage" grep -Fq '::error::codesign still failed after 3 attempts' "$FAKE_TOOL_DIR/stderr"

for action in staple validate; do
	run_with_fakes "$(lines "68|$cloudkit_dropped" "68|$cloudkit_dropped" "0|The $action action worked!")" "" \
		bash "$retry" stapler "$action" "$retry_bundle"
	assert_equal "stapler $action recovers when the ticketing service answers again" "0" "$FAKE_STATUS"
	assert_equal "stapler $action runs again while the ticketing service doesn't answer" "3" "$(call_count xcrun)"
	assert_equal "stapler $action keeps its arguments" "$(quoted stapler "$action" "$retry_bundle")" "$(call xcrun 3)"
	assert_success "passes stapler's own output through" grep -Fq "The $action action worked!" "$FAKE_TOOL_DIR/stdout"
done

run_with_fakes "$(lines "68|$cloudkit_dropped" '0|The staple action worked!')" "" bash "$retry" stapler staple -v "$retry_bundle"
assert_equal "stapler keeps verbose output on every attempt" "$(quoted stapler staple -v "$retry_bundle")" "$(call xcrun 2)"

for status in 65 66 73 77; do
	run_with_fakes "$(lines "$status|The validate action failed! Error $status." '0|')" "" bash "$retry" stapler validate "$retry_bundle"
	assert_equal "stapler keeps its status $status" "$status" "$FAKE_STATUS"
	assert_equal "stapler doesn't retry status $status" "1" "$(call_count xcrun)"
done

LPM_APPLE_SERVICE_MAX_ATTEMPTS=3 run_with_fakes "$(lines "68|$cloudkit_dropped" "68|$cloudkit_dropped" "68|$cloudkit_dropped" '0|')" "" \
	bash "$retry" stapler validate "$retry_bundle"
assert_equal "stapler gives up with its own status after the attempt budget" "68" "$FAKE_STATUS"
assert_equal "stapler runs at most the attempt budget" "3" "$(call_count xcrun)"
assert_success "reports a lasting ticketing outage" grep -Fq '::error::stapler validate still failed after 3 attempts' "$FAKE_TOOL_DIR/stderr"

for arguments in "notarytool submit" "codesign" "stapler" "stapler validate" "stapler verify /tmp/LPM.app" \
	"stapler validate /tmp/LPM.app extra" "stapler validate -q /tmp/LPM.app"; do
	# shellcheck disable=SC2086
	run_with_fakes "" "" bash "$retry" $arguments
	assert_equal "'$arguments' is a usage error" "2" "$FAKE_STATUS"
	assert_equal "'$arguments' runs no Apple tool" "0" "$(($(call_count xcrun) + $(call_count codesign)))"
done

echo "Release tooling tests passed: $TEST_COUNT"
