#!/bin/bash
set -euo pipefail

# Build script: builds with xcodebuild and copies .app to build/
# Usage: ./build-app.sh [release|debug]
#
# Produces: build/LPM Vault.app

CONFIG="${1:-release}"
APP_NAME="LPM Vault"
TEAM_ID="${LPM_TEAM_ID:-823S8YKMRW}"
SIGNING_IDENTITY="${LPM_SIGNING_IDENTITY:-Developer ID Application: Tolga Ergin (823S8YKMRW)}"
PROVISIONING_PROFILE="${LPM_VAULT_PROVISIONING_PROFILE:-}"
EXPECTED_ACCESS_GROUP="$TEAM_ID.dev.lpm.vault.shared"
EXPECTED_APPLICATION_ID="$TEAM_ID.dev.lpm.vault"
EXPECTED_PROFILE_ACCESS_GROUP="$TEAM_ID.*"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BUILD_DIR="$SCRIPT_DIR/build"
DERIVED_DATA_DIR="$BUILD_DIR/DerivedData"

cd "$SCRIPT_DIR"

# Ensure .xcodeproj exists
if [ ! -d "LPMVault.xcodeproj" ]; then
	echo "→ Generating Xcode project..."
	xcodegen generate
fi

# Map config name
if [ "$CONFIG" = "release" ]; then
	XCODE_CONFIG="Release"
else
	XCODE_CONFIG="Debug"
fi

echo "→ Building $APP_NAME ($XCODE_CONFIG)..."
mkdir -p "$BUILD_DIR"
BUILD_LOG=$(mktemp)
ENTITLEMENTS_OUTPUT=$(mktemp)
PROFILE_PLIST=$(mktemp)
trap 'rm -f "$BUILD_LOG" "$ENTITLEMENTS_OUTPUT" "$PROFILE_PLIST"' EXIT
if ! security find-identity -v -p codesigning | grep -Fq -- "\"$SIGNING_IDENTITY\""; then
	echo "✗ Signing identity is unavailable: $SIGNING_IDENTITY" >&2
	exit 1
fi
if [ -z "$PROVISIONING_PROFILE" ] || [ ! -f "$PROVISIONING_PROFILE" ]; then
	echo "✗ Set LPM_VAULT_PROVISIONING_PROFILE to the Developer ID profile for dev.lpm.vault" >&2
	exit 1
fi
security cms -D -i "$PROVISIONING_PROFILE" >"$PROFILE_PLIST"
PROFILE_TEAM_ID=$(/usr/libexec/PlistBuddy -c 'Print :TeamIdentifier:0' "$PROFILE_PLIST")
PROFILE_APPLICATION_ID=$(
	/usr/libexec/PlistBuddy -c 'Print :Entitlements:com.apple.application-identifier' "$PROFILE_PLIST" 2>/dev/null ||
		/usr/libexec/PlistBuddy -c 'Print :Entitlements:application-identifier' "$PROFILE_PLIST"
)
PROFILE_ACCESS_GROUPS=$(/usr/libexec/PlistBuddy -c 'Print :Entitlements:keychain-access-groups' "$PROFILE_PLIST")
if [ "$PROFILE_TEAM_ID" != "$TEAM_ID" ] || \
	[ "$PROFILE_APPLICATION_ID" != "$EXPECTED_APPLICATION_ID" ] || \
	! printf '%s\n' "$PROFILE_ACCESS_GROUPS" | awk \
		-v exact="$EXPECTED_ACCESS_GROUP" \
		-v wildcard="$EXPECTED_PROFILE_ACCESS_GROUP" \
		'{ value = $0; gsub(/^[[:space:]]+|[[:space:]]+$/, "", value); if (value == exact || value == wildcard) found = 1 } END { exit(found ? 0 : 1) }'; then
	echo "✗ Provisioning profile does not authorize the LPM Vault shared Keychain contract" >&2
	exit 1
fi
if ! xcodebuild \
	-project LPMVault.xcodeproj \
	-scheme LPMVault \
	-configuration "$XCODE_CONFIG" \
	-derivedDataPath "$DERIVED_DATA_DIR" \
	CODE_SIGNING_ALLOWED=NO \
	CODE_SIGNING_REQUIRED=NO \
	build >"$BUILD_LOG" 2>&1; then
	grep -E "^(Build|Compile|Link|error:|warning:|.*error:)" "$BUILD_LOG" || true
	exit 1
fi
grep -E "^(Build|Compile|Link|warning:)" "$BUILD_LOG" || true

# Use only the artifact produced by this invocation. Searching the user's
# global DerivedData can silently package a stale app from another checkout.
DERIVED_APP="$DERIVED_DATA_DIR/Build/Products/$XCODE_CONFIG/$APP_NAME.app"

if [ ! -d "$DERIVED_APP" ]; then
	echo "✗ Build failed — .app not found in DerivedData"
	exit 1
fi

# Copy to build/
rm -rf "$BUILD_DIR/$APP_NAME.app"
cp -R "$DERIVED_APP" "$BUILD_DIR/$APP_NAME.app"
cp "$PROVISIONING_PROFILE" "$BUILD_DIR/$APP_NAME.app/Contents/embedded.provisionprofile"
DEBUG_DYLIB="$BUILD_DIR/$APP_NAME.app/Contents/MacOS/$APP_NAME.debug.dylib"
if [ -f "$DEBUG_DYLIB" ]; then
	codesign --force --options runtime --timestamp=none \
		--sign "$SIGNING_IDENTITY" \
		"$DEBUG_DYLIB"
fi
codesign --force --options runtime --timestamp=none \
	--entitlements LPMVault.entitlements \
	--sign "$SIGNING_IDENTITY" \
	"$BUILD_DIR/$APP_NAME.app"
codesign --verify --deep --strict "$BUILD_DIR/$APP_NAME.app"
codesign -d --entitlements :- "$BUILD_DIR/$APP_NAME.app" >"$ENTITLEMENTS_OUTPUT" 2>/dev/null
SIGNED_ACCESS_GROUP=$(/usr/libexec/PlistBuddy -c 'Print :keychain-access-groups:0' "$ENTITLEMENTS_OUTPUT")
if [ "$SIGNED_ACCESS_GROUP" != "$EXPECTED_ACCESS_GROUP" ]; then
	echo "✗ App is missing the shared Keychain access group" >&2
	exit 1
fi
SIGNING_DETAILS=$(codesign -d --verbose=4 "$BUILD_DIR/$APP_NAME.app" 2>&1)
if ! grep -Fq "TeamIdentifier=$TEAM_ID" <<<"$SIGNING_DETAILS"; then
	echo "✗ App has the wrong Apple team identifier" >&2
	exit 1
fi
if [ "$XCODE_CONFIG" = "Release" ]; then
	APP_ENTITLEMENTS=$(<"$ENTITLEMENTS_OUTPUT")
	if grep -q 'com.apple.security.get-task-allow' <<<"$APP_ENTITLEMENTS"; then
		echo "✗ Release signature permits debugger attachment"
		exit 1
	fi
	if ! grep -Eq 'flags=.*runtime' <<<"$SIGNING_DETAILS"; then
		echo "✗ Release signature is missing the hardened runtime"
		exit 1
	fi
fi

echo "→ Built: $BUILD_DIR/$APP_NAME.app"
du -sh "$BUILD_DIR/$APP_NAME.app" | awk '{print "→ Size: " $1}'
echo ""
echo "To run:  open \"$BUILD_DIR/$APP_NAME.app\""
echo "To zip:  cd build && zip -r \"$APP_NAME-darwin-$(uname -m).zip\" \"$APP_NAME.app\""
