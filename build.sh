#!/bin/bash
# Builds Nosy.app. `./build.sh install` also copies it to /Applications.
set -euo pipefail
cd "$(dirname "$0")"
source scripts/paths.sh
APP="$BUILD_DIR/Nosy.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources" "$BUILD_DIR/module-cache"
if [[ ! -f Resources/AppIcon.icns || ! -f Resources/NosyMark.png ]]; then
    swift -module-cache-path "$BUILD_DIR/module-cache" scripts/MakeIcon.swift .
fi
swiftc -O -swift-version 6 -strict-concurrency=complete -parse-as-library \
    -target arm64-apple-macos26.0 -module-cache-path "$BUILD_DIR/module-cache" \
    Sources/*.swift -o "$APP/Contents/MacOS/Nosy"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns Resources/NosyMark.png "$APP/Contents/Resources/"
if [[ -d Resources/Fonts ]]; then
    mkdir -p "$APP/Contents/Resources/Fonts"
    cp -R Resources/Fonts/. "$APP/Contents/Resources/Fonts/"
fi
xattr -cr "$APP"
# Set NOSY_CODESIGN_IDENTITY to use a local signing identity; default to ad-hoc.
IDENTITY="${NOSY_CODESIGN_IDENTITY:--}"
if ! codesign --force --options runtime --entitlements Resources/Entitlements.plist --sign "$IDENTITY" "$APP"; then
    printf 'SIGNING NOTE: Developer ID unavailable; signing ad-hoc (mic permission may reset on rebuild).\n'
    codesign --force --options runtime --entitlements Resources/Entitlements.plist --sign - "$APP"
fi
codesign --verify --strict "$APP"
printf 'BUILD PASS: %s\n' "$APP"
if [[ "${1:-}" == install ]]; then
    osascript -e 'quit app "Nosy"' 2>/dev/null || true
    osascript -e 'quit app "Lecture Transcriber"' 2>/dev/null || true
    rm -rf '/Applications/Lecture Transcriber.app'
    rm -rf '/Applications/Nosy.app'
    ditto "$APP" '/Applications/Nosy.app'
    printf 'Installed /Applications/Nosy.app\n'
fi
