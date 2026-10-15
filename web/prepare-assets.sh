#!/bin/sh
set -eu

root=$1
mkdir -p "$root/assets"
for source in style.css site.js analytics.js; do
    digest=$(sha256sum "$root/$source" | cut -d ' ' -f 1)
    asset="${source%.*}.$digest.${source##*.}"
    cp "$root/$source" "$root/assets/$asset"
    for page in index.html netlify-connected.html; do
        sed -i "s|/$source\(?v=[a-f0-9]*\)\?\"|/assets/$asset\"|g" "$root/$page"
    done
done
