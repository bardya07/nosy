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
# Build and package outside the checkout: iCloud Drive (Desktop/Documents sync)
# adds FinderInfo/file-provider attributes to bundles, which breaks code signatures.
export BUILD_DIR="$HOME/Library/Caches/Nosy Release"
APP="$BUILD_DIR/Nosy.app"
DIST="$ROOT/dist"
mkdir -p "$DIST"
STAGING=$(mktemp -d "${TMPDIR:-/tmp}/nosy-release.XXXXXX")
MOUNTED=false
cleanup() {
    local status=$?
    if [[ "$MOUNTED" == true ]]; then
        if ! hdiutil detach "$STAGING/mount"; then
            printf 'Could not detach release image; staging retained at %s\n' "$STAGING" >&2
            exit 1
        fi
    fi
    if [[ "$status" -ne 0 ]]; then
        printf 'Release failed; staging retained at %s\n' "$STAGING" >&2
    else
        rm -rf "$STAGING"
    fi
    exit "$status"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

# build.sh signs the static whisper-cli first, then the app with its microphone
# entitlement. Both receive hardened runtime and a secure timestamp; no --deep signing.
# Rebuild both helpers from their checksum-verified pinned archives for each release.
./scripts/build-whisper.sh
./scripts/build-llama.sh
# Reject missing or unexpected build metadata before packaging either helper.
printf 'whisper.cpp v1.9.5\nsource sha256: ff1a9053feb509ff9d7729703355541ae9690073a6b1c40eb692c962e0dc1720\narm64; macOS 14.0; static GGML; Core ML encoder with fallback; embedded Metal shaders\n' | cmp -s - vendor/whisper/BUILD-INFO.txt || {
    printf 'Whisper helper build metadata does not match the release pin.\n' >&2; exit 1;
}
printf 'llama.cpp b11869 (d327bf1f0780f87b8c01b367b61853b0c291d7c4)\nsource sha256: f808461a7a07acf0b60c0fa08c5bc65bb7641a377d63b758569c941c12ad8a0c\narm64; macOS 14.0; static GGML; embedded Metal shaders\n' | cmp -s - vendor/llama/BUILD-INFO.txt || {
    printf 'Llama helper build metadata does not match the release pin.\n' >&2; exit 1;
}
./build.sh
codesign --verify --strict --deep "$APP"
VERSION=$(plutil -extract CFBundleShortVersionString raw -o - "$APP/Contents/Info.plist")
BUILD_NUMBER=$(plutil -extract CFBundleVersion raw -o - "$APP/Contents/Info.plist")
[[ "$BUILD_NUMBER" =~ ^[0-9]+$ ]] || { printf "Invalid build number: %s\n" "$BUILD_NUMBER" >&2; exit 1; }
# Increment CFBundleVersion for every release, including patch releases.
EXPECTED_KEY=$(plutil -extract SUPublicEDKey raw -o - "$APP/Contents/Info.plist")
[[ $(vendor/sparkle/bin/generate_keys -p) == "$EXPECTED_KEY" ]] || {
    printf "Sparkle Keychain public key does not match the app.\n" >&2; exit 1;
}
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
# HFS+ images reject copied extended attributes inside signed bundles.
ditto --norsrc --noextattr --noqtn "$APP" "$STAGING/payload/Nosy.app"
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
# A read-only HFS+ mount can carry system-added attributes that strict codesign
# rejects; verify the copy a user gets by dragging Nosy to Applications instead.
ditto "$STAGING/mount/Nosy.app" "$STAGING/installed/Nosy.app"
codesign --verify --strict --deep "$STAGING/installed/Nosy.app" || {
    xattr -lrs "$STAGING/mount/Nosy.app" | grep -v provenance >&2 || true
    exit 1
}
xcrun stapler validate "$STAGING/installed/Nosy.app"
spctl -a -vv "$STAGING/installed/Nosy.app" 2>&1 | tee "$STAGING/app-assessment.txt"
grep -q 'source=Notarized Developer ID' "$STAGING/app-assessment.txt"
[[ $(readlink "$STAGING/mount/Applications") == /Applications ]]
hdiutil detach "$STAGING/mount"
MOUNTED=false

# Sign the final stapled bytes; stapling after signing would invalidate the signature.
SIGNATURE=$(vendor/sparkle/bin/sign_update -p "$DMG")
[[ "$SIGNATURE" =~ ^[A-Za-z0-9+/]+={0,2}$ ]] || { printf 'Invalid Sparkle signature.\n' >&2; exit 1; }
vendor/sparkle/bin/sign_update --verify "$DMG" "$SIGNATURE"
LENGTH=$(stat -f %z "$DMG")
PUB_DATE=$(LC_ALL=C date -u '+%a, %d %b %Y %H:%M:%S +0000')
cat > "$STAGING/appcast.xml" <<EOF
<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    <title>Nosy Updates</title>
    <item>
      <title>Nosy $VERSION</title>
      <pubDate>$PUB_DATE</pubDate>
      <sparkle:version>$BUILD_NUMBER</sparkle:version>
      <sparkle:shortVersionString>$VERSION</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>14.0</sparkle:minimumSystemVersion>
      <enclosure url="https://github.com/bardya07/nosy/releases/download/v$VERSION/Nosy-$VERSION.dmg" sparkle:edSignature="$SIGNATURE" length="$LENGTH" type="application/octet-stream" />
    </item>
  </channel>
</rss>
EOF
xmllint --noout "$STAGING/appcast.xml"
mv -f "$DMG" "$DIST/Nosy-$VERSION.dmg"
mv -f "$STAGING/appcast.xml" "$DIST/appcast.xml"
printf 'Upload these files to the GitHub release v%s:\n  %s\n  %s\n' "$VERSION" "$DIST/Nosy-$VERSION.dmg" "$DIST/appcast.xml"
printf 'RELEASE PASS: %s (%s bytes)\n' "$DIST/Nosy-$VERSION.dmg" \
    "$(stat -f %z "$DIST/Nosy-$VERSION.dmg")"
