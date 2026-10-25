#!/bin/bash
set -euo pipefail

version="${1:?Usage: package-app.sh VERSION APP_PATH}"
app="${2:?Usage: package-app.sh VERSION APP_PATH}"
if [[ ! "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-dev\.[0-9a-f]+)?$ ]]; then
    printf 'Invalid version: %s (expected X.Y.Z or X.Y.Z-dev.COMMIT)\n' "$version" >&2
    exit 1
fi

actual_version=$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")
if [[ "$actual_version" != "$version" ]]; then
    printf 'Bundle version %s does not match requested version %s\n' "$actual_version" "$version" >&2
    exit 1
fi
lipo -verify_arch arm64 "$app/Contents/MacOS/Cortes"
codesign --verify --deep --strict "$app"
if [[ -e "$app/Contents/Resources/CortesKit_CortesKit.bundle/Contents/Resources/Scenarios" ]]; then
    printf 'Release bundle still contains demo scenarios\n' >&2
    exit 1
fi
if strings "$app/Contents/MacOS/Cortes" | grep -E 'Demo Chat|Replay \(offline\)|friday-release|Public pressure about a slipped deadline|Scenario resources are missing' >/dev/null; then
    printf 'Release executable still contains demo UI\n' >&2
    exit 1
fi

mkdir -p dist
archive="cortes-${version}-macos-arm64.zip"
# ditto preserves the bundle layout, executable bits and signature metadata.
ditto -c -k --sequesterRsrc --keepParent "$app" "dist/$archive"
(cd dist && shasum -a 256 "$archive" > SHA256SUMS)
printf 'Packaged dist/%s and dist/SHA256SUMS\n' "$archive"
