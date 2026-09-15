#!/bin/bash
set -euo pipefail

destination="${1:?Usage: fetch-sparkle-tools.sh NEW_DIRECTORY}"
[ ! -e "$destination" ] || { echo "Destination already exists" >&2; exit 1; }
archive="$(mktemp)"
trap 'rm -f "$archive"' EXIT
curl --fail --location --proto '=https' --tlsv1.2 --retry 3 \
	https://github.com/sparkle-project/Sparkle/releases/download/2.10.0/Sparkle-2.10.0.tar.xz \
	-o "$archive"
printf '%s  %s\n' c2bf58aa8387266ac179357b1415d6f2635f044da8be41042af32425dae6da0c "$archive" | shasum -a 256 -c -
mkdir -p "$destination"
tar -xJf "$archive" -C "$destination"
