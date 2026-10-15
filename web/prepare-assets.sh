#!/bin/sh
set -eu

root=$1
mkdir -p "$root/assets"
for source in style.css site.js analytics.js; do
    digest=$(sha256sum "$root/$source" | cut -d ' ' -f 1)
    asset="${source%.*}.$digest.${source##*.}"
    cp "$root/$source" "$root/assets/$asset"
    sed -i "s|/$source\(?v=[a-f0-9]*\)\?\"|/assets/$asset\"|g" "$root/index.html"
done
