#!/bin/bash
# Builds Nosy.app. `./build.sh install` also copies it to /Applications.
set -euo pipefail
cd "$(dirname "$0")"
source scripts/paths.sh
APP="$BUILD_DIR/Nosy.app"
WHISPER="$PWD/vendor/whisper/whisper-cli"
[[ -x "$WHISPER" ]] || { printf 'Build the bundled speech engine first: ./scripts/build-whisper.sh\n' >&2; exit 1; }
[[ $(lipo -archs "$WHISPER") == arm64 ]] || { printf 'whisper-cli must be arm64.\n' >&2; exit 1; }
otool -L "$WHISPER" | awk 'NR > 1 && $1 !~ /^\/usr\/lib\// && $1 !~ /^\/System\/Library\// { bad = 1 } END { exit bad }'
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources" "$BUILD_DIR/module-cache"
if [[ ! -f Resources/AppIcon.icns || ! -f Resources/NosyMark.png ]]; then
    swift -module-cache-path "$BUILD_DIR/module-cache" scripts/MakeIcon.swift .
fi
swiftc -O -swift-version 6 -strict-concurrency=complete -parse-as-library \
    -target arm64-apple-macos14.0 -module-cache-path "$BUILD_DIR/module-cache" \
    Sources/*.swift -o "$APP/Contents/MacOS/Nosy"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns Resources/NosyMark.png "$APP/Contents/Resources/"
install -m 755 "$WHISPER" "$APP/Contents/Helpers/whisper-cli"
cp THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/"
if [[ -d Resources/Fonts ]]; then
    mkdir -p "$APP/Contents/Resources/Fonts"
    cp -R Resources/Fonts/. "$APP/Contents/Resources/Fonts/"
fi
xattr -cr "$APP"
# Set NOSY_CODESIGN_IDENTITY to use a local signing identity; default to ad-hoc.
IDENTITY="${NOSY_CODESIGN_IDENTITY:--}"
SIGN_OPTIONS=(--force --options runtime --sign "$IDENTITY")
if [[ "$IDENTITY" != - ]]; then SIGN_OPTIONS+=(--timestamp); fi
# Sign nested code first with the same identity and hardened runtime. An explicit
# identity must succeed: silently falling back to ad-hoc would break notarization.
codesign "${SIGN_OPTIONS[@]}" "$APP/Contents/Helpers/whisper-cli"
codesign "${SIGN_OPTIONS[@]}" --entitlements Resources/Entitlements.plist "$APP"
codesign --verify --strict "$APP/Contents/Helpers/whisper-cli"
codesign --verify --deep --strict "$APP"
printf 'BUILD PASS: %s\n' "$APP"
if [[ "${1:-}" == install ]]; then
    osascript -e 'quit app "Nosy"' 2>/dev/null || true
    osascript -e 'quit app "Lecture Transcriber"' 2>/dev/null || true
    rm -rf '/Applications/Lecture Transcriber.app'
    rm -rf '/Applications/Nosy.app'
    ditto "$APP" '/Applications/Nosy.app'
    printf 'Installed /Applications/Nosy.app\n'
fi
