#!/bin/bash
set -euo pipefail

release_dir="${1:?Usage: generate-appcast.sh RELEASE_DIRECTORY SPARKLE_TOOLS_DIRECTORY}"
tools_dir="${2:?Sparkle tools directory is required}"
manifest="$release_dir/release-manifest.json"
version="$(jq -er '.version' "$manifest")"
build="$(jq -er '.build' "$manifest")"
[[ "$version" =~ ^[0-9]+\.[0-9]+(\.[0-9]+)?$ ]] || exit 1
[[ "$build" =~ ^[0-9]+(\.[0-9]+){0,2}$ ]] || exit 1
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cp "$release_dir/LPM-Vault-$version.dmg" "$work/"
key_args=(--account dev.lpm.vault.sparkle)
if [ -n "${SPARKLE_PRIVATE_KEY:-}" ]; then
	key_args=(--ed-key-file -)
fi
printf '%s' "${SPARKLE_PRIVATE_KEY:-}" | "$tools_dir/bin/generate_appcast" \
	"${key_args[@]}" --maximum-deltas 0 \
	--download-url-prefix "https://vault.lpm.dev/releases/v$version/" \
	--link https://vault.lpm.dev/ "$work"
python3 "$(dirname "$0")/verify-appcast.py" "$work/appcast.xml" "$release_dir"
printf '%s' "${SPARKLE_PRIVATE_KEY:-}" | "$tools_dir/bin/sign_update" \
	"${key_args[@]}" --verify "$work/appcast.xml"
signature="$(python3 -c 'import sys, xml.etree.ElementTree as E; print(E.parse(sys.argv[1]).find("./channel/item/enclosure").get("{http://www.andymatuschak.org/xml-namespaces/sparkle}edSignature"))' "$work/appcast.xml")"
printf '%s' "${SPARKLE_PRIVATE_KEY:-}" | "$tools_dir/bin/sign_update" \
	"${key_args[@]}" --verify "$work/LPM-Vault-$version.dmg" "$signature"
cp "$work/appcast.xml" "$release_dir/appcast.xml"
cp "$release_dir/LPM-Vault-$version.dmg" "$release_dir/LPM-Vault.dmg"
(cd "$release_dir" && shasum -a 256 appcast.xml LPM-Vault.dmg >> checksums.txt)
