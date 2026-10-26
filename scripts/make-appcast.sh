#!/bin/bash
set -euo pipefail

version="${1:?Usage: make-appcast.sh VERSION APP_PATH SPARKLE_TOOLS}"
app="${2:?Missing app path}"
tools="${3:?Missing Sparkle tools path}"
archive="cortes-${version}-macos-arm64.zip"
image="cortes-${version}-macos-arm64.dmg"
if [[ -z "${SPARKLE_ED_PRIVATE_KEY:-}" ]]; then
    printf 'SPARKLE_ED_PRIVATE_KEY is required to sign the update feed\n' >&2
    exit 1
fi
if [[ ! -f "dist/$archive" || ! -f "dist/$image" || ! -x "$tools/generate_appcast" ]]; then
    printf 'Build and package the app before generating its update feed\n' >&2
    exit 1
fi

# A fresh directory prevents stale versions or delta files from entering this feed.
stage="$(mktemp -d)"
trap 'rm -f "$stage/$archive" "$stage/appcast.xml"; rmdir "$stage"' EXIT
cp "dist/$archive" "$stage/"
# Keep the installer out of this directory so Sparkle offers only the update ZIP.
printf '%s' "$SPARKLE_ED_PRIVATE_KEY" | "$tools/generate_appcast" --ed-key-file - \
    --download-url-prefix "https://github.com/mrcat71/cortes/releases/download/v${version}/" \
    --link https://github.com/mrcat71/cortes \
    -o "$stage/appcast.xml" "$stage"
swift scripts/check-appcast.swift "$stage/appcast.xml" "dist/$archive" "$app/Contents/Info.plist"
printf '%s' "$SPARKLE_ED_PRIVATE_KEY" | "$tools/sign_update" --verify --ed-key-file - "$stage/appcast.xml"
cp "$stage/appcast.xml" dist/appcast.xml
(cd dist && shasum -a 256 "$archive" "$image" appcast.xml > SHA256SUMS)
