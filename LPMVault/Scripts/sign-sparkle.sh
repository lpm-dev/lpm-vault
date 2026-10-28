#!/bin/bash
set -euo pipefail

SIGN_SPARKLE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

sign_sparkle() {
	local app="$1" identity="$2" timestamp="$3"
	local framework="$app/Contents/Frameworks/Sparkle.framework"
	local component
	for component in \
		"Versions/B/XPCServices/Downloader.xpc" \
		"Versions/B/XPCServices/Installer.xpc" \
		"Versions/B/Autoupdate" \
		"Versions/B/Updater.app" \
		"."; do
		[ -e "$framework/$component" ] || { echo "Missing Sparkle component: $component" >&2; return 1; }
		bash "$SIGN_SPARKLE_DIR/with-apple-service-retry.sh" codesign --force --options runtime "$timestamp" \
			--sign "$identity" "$framework/$component"
	done
}

if [ "${BASH_SOURCE[0]}" = "$0" ]; then
	sign_sparkle "$@"
fi
