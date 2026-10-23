#!/bin/bash
# Build, notarize, and verify a Developer ID DMG. Never installs or launches Nosy.
set -euo pipefail
cd "$(dirname "$0")/.."
ROOT="$PWD"
[[ $(uname -s) == Darwin ]] || { printf 'Releases require macOS.\n' >&2; exit 1; }
[[ $# -eq 0 ]] || { printf 'Usage: ./scripts/release.sh\n' >&2; exit 1; }

export NOSY_CODESIGN_IDENTITY="${NOSY_CODESIGN_IDENTITY:-Developer ID Application: Bardya Nassirian (RH4G8CYPSN)}"
[[ "$NOSY_CODESIGN_IDENTITY" == 'Developer ID Application: '* ]] || {
    printf 'A Developer ID Application signing identity is required.\n' >&2
    exit 1
}
NOTARY_PROFILE="${NOSY_NOTARY_PROFILE:-nosy-notary}"
# Keep release builds separate from local builds and entirely in this checkout.
export BUILD_DIR="$ROOT/build/release"
APP="$BUILD_DIR/Nosy.app"
DIST="$ROOT/dist"
mkdir -p "$DIST"
STAGING=$(mktemp -d "$DIST/.release.XXXXXX")
MOUNTED=false
cleanup() {
    local status=$?
    if [[ "$MOUNTED" == true ]]; then
        if ! hdiutil detach "$STAGING/mount"; then
            printf 'Could not detach release image; staging retained at %s\n' "$STAGING" >&2
            exit 1
        fi
    fi
    rm -rf "$STAGING"
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# build.sh signs the static whisper-cli first, then the app with its microphone
# entitlement. Both receive hardened runtime and a secure timestamp; no --deep signing.
[[ -x vendor/whisper/whisper-cli ]] || ./scripts/build-whisper.sh
./build.sh
codesign --verify --strict --deep "$APP"
VERSION=$(plutil -extract CFBundleShortVersionString raw -o - "$APP/Contents/Info.plist")
[[ "$VERSION" =~ ^[0-9]+(\.[0-9]+)*$ ]] || {
    printf 'Invalid release version in Info.plist: %s\n' "$VERSION" >&2
    exit 1
}

notarize() {
    local artifact=$1 label=$2 submission status submit_exit=0
    local result="$DIST/Nosy-$VERSION-$label-notary.json"
    local log="$DIST/Nosy-$VERSION-$label-notary-log.json"
    printf 'Submitting %s for notarization (profile: %s)…\n' "$artifact" "$NOTARY_PROFILE"
    xcrun notarytool submit "$artifact" --keychain-profile "$NOTARY_PROFILE" \
        --wait --output-format json > "$result" || submit_exit=$?
    cat "$result"
    submission=$(plutil -extract id raw -o - "$result" 2>/dev/null || true)
    status=$(plutil -extract status raw -o - "$result" 2>/dev/null || true)
    # Fetch and print Apple's diagnostics even on rejection/nonzero exit. Keep
    # successful logs too, so warnings and submission IDs remain reviewable.
    if [[ -n "$submission" ]]; then
        xcrun notarytool log "$submission" --keychain-profile "$NOTARY_PROFILE" "$log"
        cat "$log"
    else
        printf 'No submission ID returned; cannot fetch notarytool log. See %s\n' "$result" >&2
    fi
    if [[ "$submit_exit" -ne 0 || "$status" != Accepted ]]; then
        printf 'Notarization failed (%s); see %s\n' "${status:-submission error}" "$result" >&2
        return 1
    fi
}

# Staple the app before packaging, so its ticket stays with it after a drag-copy
# out of the DMG, including when Gatekeeper has no network connection.
ditto -c -k --keepParent "$APP" "$STAGING/Nosy-$VERSION.zip"
notarize "$STAGING/Nosy-$VERSION.zip" app
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"
codesign --verify --strict --deep "$APP"

mkdir -p "$STAGING/payload" "$STAGING/mount"
ditto "$APP" "$STAGING/payload/Nosy.app"
ln -s /Applications "$STAGING/payload/Applications"
DMG="$STAGING/Nosy-$VERSION.dmg"
hdiutil create -volname Nosy -srcfolder "$STAGING/payload" -fs HFS+ \
    -format UDZO "$DMG"
codesign --force --sign "$NOSY_CODESIGN_IDENTITY" --timestamp "$DMG"
codesign --verify --strict "$DMG"
hdiutil verify "$DMG"
notarize "$DMG" dmg
xcrun stapler staple "$DMG"
codesign --verify --strict "$DMG"
spctl -a -t open --context context:primary-signature -v "$DMG"
xcrun stapler validate "$DMG"

# Assess the actual shipped app without launching it or touching /Applications.
hdiutil attach -readonly -nobrowse -mountpoint "$STAGING/mount" "$DMG"
MOUNTED=true
codesign --verify --strict --deep "$STAGING/mount/Nosy.app"
xcrun stapler validate "$STAGING/mount/Nosy.app"
spctl -a -vv "$STAGING/mount/Nosy.app" 2>&1 | tee "$STAGING/app-assessment.txt"
grep -q 'source=Notarized Developer ID' "$STAGING/app-assessment.txt"
[[ $(readlink "$STAGING/mount/Applications") == /Applications ]]
hdiutil detach "$STAGING/mount"
MOUNTED=false

mv -f "$DMG" "$DIST/Nosy-$VERSION.dmg"
printf 'RELEASE PASS: %s (%s bytes)\n' "$DIST/Nosy-$VERSION.dmg" \
    "$(stat -f %z "$DIST/Nosy-$VERSION.dmg")"
