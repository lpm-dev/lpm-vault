#!/bin/bash
set -euo pipefail

# Build script: builds with xcodebuild and copies .app to build/
# Usage: ./build-app.sh [release|debug]
#
# Produces: build/LPM Vault.app

CONFIG="${1:-release}"
APP_NAME="LPM Vault"

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
trap 'rm -f "$BUILD_LOG"' EXIT
if ! xcodebuild \
	-project LPMVault.xcodeproj \
	-scheme LPMVault \
	-configuration "$XCODE_CONFIG" \
	-derivedDataPath "$DERIVED_DATA_DIR" \
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
codesign --verify --deep --strict "$BUILD_DIR/$APP_NAME.app"
if [ "$XCODE_CONFIG" = "Release" ]; then
	APP_ENTITLEMENTS=$(codesign -d --entitlements :- "$BUILD_DIR/$APP_NAME.app" 2>/dev/null)
	if grep -q 'com.apple.security.get-task-allow' <<<"$APP_ENTITLEMENTS"; then
		echo "✗ Release signature permits debugger attachment"
		exit 1
	fi
	SIGNING_DETAILS=$(codesign -d --verbose=4 "$BUILD_DIR/$APP_NAME.app" 2>&1)
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
