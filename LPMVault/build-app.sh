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
xcodebuild \
	-project LPMVault.xcodeproj \
	-scheme LPMVault \
	-configuration "$XCODE_CONFIG" \
	build \
	2>&1 | grep -E "^(Build|Compile|Link|error:|warning:.*error)" || true

# Find the built .app in DerivedData
DERIVED_APP=$(find ~/Library/Developer/Xcode/DerivedData/LPMVault-*/Build/Products/"$XCODE_CONFIG" -name "$APP_NAME.app" -maxdepth 1 2>/dev/null | head -1)

if [ -z "$DERIVED_APP" ]; then
	echo "✗ Build failed — .app not found in DerivedData"
	exit 1
fi

# Copy to build/
mkdir -p "$BUILD_DIR"
rm -rf "$BUILD_DIR/$APP_NAME.app"
cp -R "$DERIVED_APP" "$BUILD_DIR/$APP_NAME.app"

echo "→ Built: $BUILD_DIR/$APP_NAME.app"
du -sh "$BUILD_DIR/$APP_NAME.app" | awk '{print "→ Size: " $1}'
echo ""
echo "To run:  open \"$BUILD_DIR/$APP_NAME.app\""
echo "To zip:  cd build && zip -r \"$APP_NAME-darwin-$(uname -m).zip\" \"$APP_NAME.app\""
