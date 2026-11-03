#!/bin/bash
# Builds Nosy.app. `./build.sh install` also copies it to /Applications.
set -euo pipefail
cd "$(dirname "$0")"
source scripts/paths.sh
source scripts/audio-shim.sh
APP="$BUILD_DIR/Nosy.app"
WHISPER="$PWD/vendor/whisper/whisper-cli"
LLAMA="$PWD/vendor/llama/nosy-llama"
SPARKLE="$PWD/vendor/sparkle"
[[ -f "$SPARKLE/Sparkle.framework/Sparkle" && -x "$SPARKLE/bin/generate_keys" && -x "$SPARKLE/bin/sign_update" && -x "$SPARKLE/bin/generate_appcast" ]] || ./scripts/fetch-sparkle.sh
[[ -x "$LLAMA" ]] || { printf 'Build the bundled summary engine first: ./scripts/build-llama.sh\n' >&2; exit 1; }
[[ $(lipo -archs "$LLAMA") == arm64 ]] || { printf 'nosy-llama must be arm64.\n' >&2; exit 1; }
otool -L "$LLAMA" | awk 'NR > 1 && $1 !~ /^\/usr\/lib\// && $1 !~ /^\/System\/Library\// { bad = 1 } END { exit bad }'
[[ -x "$WHISPER" ]] || { printf 'Build the bundled speech engine first: ./scripts/build-whisper.sh\n' >&2; exit 1; }
[[ $(lipo -archs "$WHISPER") == arm64 ]] || { printf 'whisper-cli must be arm64.\n' >&2; exit 1; }
otool -L "$WHISPER" | awk 'NR > 1 && $1 !~ /^\/usr\/lib\// && $1 !~ /^\/System\/Library\// { bad = 1 } END { exit bad }'
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Helpers" "$APP/Contents/Resources" "$BUILD_DIR/module-cache"
# Keep the owner's supplied app icon and header artwork authoritative.
swift -module-cache-path "$BUILD_DIR/module-cache" scripts/MakeIcon.swift .
swiftc -O -swift-version 6 -strict-concurrency=complete -parse-as-library \
    -target arm64-apple-macos14.0 -module-cache-path "$BUILD_DIR/module-cache" \
    -F "$SPARKLE" -framework Sparkle -Xlinker -rpath -Xlinker @executable_path/../Frameworks \
    "${AUDIO_SHIM[@]}" Sources/*.swift -o "$APP/Contents/MacOS/Nosy"
# The MCP server that lets Claude Desktop and other AI apps read transcripts. Standard library only.
swiftc -O -swift-version 6 -strict-concurrency=complete -parse-as-library \
    -target arm64-apple-macos14.0 -module-cache-path "$BUILD_DIR/module-cache" \
    Connector/*.swift -o "$APP/Contents/Helpers/nosy-mcp"
cp -R Resources/Vocabulary "$APP/Contents/Resources/"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns Resources/NosyMark.png Resources/GitHubMark.png "$APP/Contents/Resources/"
# Compile before signing. Keep the supplied static AppIcon.icns for macOS 14–15.
if xcrun --find actool >/dev/null 2>&1; then
    ICON_BUILD_DIR=$(mktemp -d "$BUILD_DIR/icon.XXXXXX")
    if xcrun actool Resources/Brand/Nosy.icon --compile "$ICON_BUILD_DIR" \
        --app-icon Nosy --platform macosx --target-device mac \
        --minimum-deployment-target 14.0 \
        --output-partial-info-plist "$ICON_BUILD_DIR/partial.plist"; then
        cp "$ICON_BUILD_DIR/Assets.car" "$APP/Contents/Resources/Assets.car"
        rm -rf "$ICON_BUILD_DIR"
    else
        rm -rf "$ICON_BUILD_DIR"
        printf 'Icon compilation failed.\n' >&2
        exit 1
    fi
else
    printf 'Note: actool unavailable; using the static app icon.\n'
    /usr/libexec/PlistBuddy -c 'Delete :CFBundleIconName' "$APP/Contents/Info.plist"
fi
install -m 755 "$WHISPER" "$APP/Contents/Helpers/whisper-cli"
install -m 755 "$LLAMA" "$APP/Contents/Helpers/nosy-llama"
mkdir -p "$APP/Contents/Frameworks"
ditto "$SPARKLE/Sparkle.framework" "$APP/Contents/Frameworks/Sparkle.framework"
cp THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/"
xattr -cr "$APP"
# Set NOSY_CODESIGN_IDENTITY to use a local signing identity; default to ad-hoc.
IDENTITY="${NOSY_CODESIGN_IDENTITY:--}"
SIGN_OPTIONS=(--force --options runtime --sign "$IDENTITY")
if [[ "$IDENTITY" != - ]]; then SIGN_OPTIONS+=(--timestamp); fi
# Sign nested code first with the same identity and hardened runtime. An explicit
# identity must succeed: silently falling back to ad-hoc would break notarization.
SPARKLE_VERSION="$APP/Contents/Frameworks/Sparkle.framework/Versions/B"
for service in "$SPARKLE_VERSION"/XPCServices/*.xpc; do
    codesign "${SIGN_OPTIONS[@]}" --preserve-metadata=entitlements "$service"
done
codesign "${SIGN_OPTIONS[@]}" "$SPARKLE_VERSION/Autoupdate"
codesign "${SIGN_OPTIONS[@]}" "$SPARKLE_VERSION/Updater.app"
codesign "${SIGN_OPTIONS[@]}" "$APP/Contents/Frameworks/Sparkle.framework"
codesign "${SIGN_OPTIONS[@]}" "$APP/Contents/Helpers/whisper-cli"
codesign "${SIGN_OPTIONS[@]}" "$APP/Contents/Helpers/nosy-mcp"
codesign "${SIGN_OPTIONS[@]}" "$APP/Contents/Helpers/nosy-llama"
codesign "${SIGN_OPTIONS[@]}" --entitlements Resources/Entitlements.plist "$APP"
codesign --verify --strict "$APP/Contents/Helpers/whisper-cli"
codesign --verify --strict "$APP/Contents/Helpers/nosy-mcp"
codesign --verify --strict "$APP/Contents/Helpers/nosy-llama"
codesign --verify --deep --strict "$APP"
printf 'BUILD PASS: %s\n' "$APP"
if [[ "${1:-}" == install ]]; then
    # Recheck after compilation, immediately before quitting/replacing the installed app.
    python3 - <<'PY'
import json, pathlib, sys
audio = pathlib.Path.home() / 'Library/Application Support/Nosy/audio'
sidecars = list(audio.glob('*.json'))
if sidecars:
    latest = max(sidecars, key=lambda path: path.stat().st_mtime_ns)
    try:
        status = json.loads(latest.read_text())['status']
    except (OSError, ValueError, KeyError):
        sys.exit('INSTALL BLOCKED: the newest recording sidecar could not be checked.')
    if status in ('recording', 'transcribing'):
        sys.exit('INSTALL BLOCKED: Nosy is still recording or transcribing. Finish that work first.')
PY
    osascript -e 'quit app "Nosy"' 2>/dev/null || true
    osascript -e 'quit app "Lecture Transcriber"' 2>/dev/null || true
    rm -rf '/Applications/Lecture Transcriber.app'
    rm -rf '/Applications/Nosy.app'
    ditto "$APP" '/Applications/Nosy.app'
    printf 'Installed /Applications/Nosy.app\n'
fi
