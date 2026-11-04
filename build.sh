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
SIGN_OPTIONS=(--force --sign "$IDENTITY")
# Ad-hoc signatures have no Team ID, so hardened runtime's library validation
# rejects even the re-signed Sparkle framework. Keep runtime for signed releases.
if [[ "$IDENTITY" != - ]]; then SIGN_OPTIONS+=(--options runtime --timestamp); fi
# Sign nested code first with the same identity. An explicit identity must
# succeed: silently falling back to ad-hoc would break notarization.
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
    # Stage on the destination volume before asking the running app to quit.
    INSTALL_STAGE=$(mktemp -d '/Applications/.Nosy-install.XXXXXX')
    KEEP_INSTALL_STAGE=false
    cleanup_install() {
        if [[ "$KEEP_INSTALL_STAGE" == true ]]; then
            printf 'Install backup retained at %s\n' "$INSTALL_STAGE" >&2
        else
            rm -rf "$INSTALL_STAGE"
        fi
    }
    trap cleanup_install EXIT
    ditto "$APP" "$INSTALL_STAGE/Nosy.app"
    codesign --verify --deep --strict "$INSTALL_STAGE/Nosy.app"

    # A later completed recording can be newer than an earlier active job.
    # Check every sidecar, including unmigrated legacy and overridden support paths.
    python3 - <<'PYTHON'
import datetime, json, math, os, pathlib, sys, uuid
home = pathlib.Path.home() / 'Library/Application Support'
roots = {home / 'Nosy', home / 'Lecture Transcriber'}
if os.environ.get('NOSY_SUPPORT_DIR'):
    roots.add(pathlib.Path(os.environ['NOSY_SUPPORT_DIR']))
def is_record_name(name):
    if not name.endswith('.json') or name.endswith('.segments.json'):
        return False
    stem = name[:-5]
    # Core.recover recognizes only this exact helper scratch naming scheme.
    if stem.startswith('.whisper-') and len(stem) > 46 and stem[-37] == '-':
        try:
            uuid.UUID(stem[-36:])
            return False
        except ValueError:
            pass
    # SessionRecord.read rejects IDs containing '..' or a slash.
    return '..' not in stem and '/' not in stem

for root in roots:
    audio = root / 'audio'
    try:
        with os.scandir(audio) as entries:
            sidecars = [pathlib.Path(entry.path) for entry in entries if is_record_name(entry.name)]
    except FileNotFoundError:
        continue
    except OSError:
        sys.exit(f'INSTALL BLOCKED: could not inspect recording sidecars in {audio}.')
    for sidecar in sidecars:
        try:
            record = json.loads(sidecar.read_text())
            if (not isinstance(record, dict) or record.get('id') != sidecar.stem
                    or any(not isinstance(record.get(key), str) for key in ('lecture', 'session', 'startedAt'))):
                raise ValueError('invalid recording')
            for key in ('startedAt', 'endedAt', 'transcribedAt'):
                value = record.get(key)
                if value is not None:
                    if not isinstance(value, str):
                        raise ValueError('invalid date')
                    parsed = datetime.datetime.fromisoformat(value.replace('Z', '+00:00'))
                    if parsed.tzinfo is None:
                        raise ValueError('date has no timezone')
            for key in ('transcriptPath', 'transcriptID', 'error'):
                if record.get(key) is not None and not isinstance(record[key], str):
                    raise ValueError('invalid optional field')
            if record.get('dismissed') is not None and not isinstance(record['dismissed'], bool):
                raise ValueError('invalid dismissed flag')
            terms = record.get('vocabularyTerms')
            if terms is not None and (not isinstance(terms, list) or any(not isinstance(term, str) for term in terms)):
                raise ValueError('invalid vocabulary')
            markers = record.get('markers')
            if markers is not None:
                if not isinstance(markers, list):
                    raise ValueError('invalid markers')
                for marker in markers:
                    if not isinstance(marker, dict) or not isinstance(marker.get('label'), str):
                        raise ValueError('invalid marker')
                    t = marker.get('t')
                    if isinstance(t, bool) or not isinstance(t, (int, float)) or not math.isfinite(t) or not 0 <= t < 2**63:
                        raise ValueError('invalid marker timestamp')
            status = record['status']
            if status not in ('recording', 'transcribing', 'done', 'failed'):
                raise ValueError('invalid status')
        except (OSError, ValueError, KeyError, TypeError):
            sys.exit(f'INSTALL BLOCKED: recording sidecar could not be checked: {sidecar}')
        if status in ('recording', 'transcribing'):
            sys.exit('INSTALL BLOCKED: Nosy has unfinished recording or transcription work. Finish that work first.')
PYTHON
    # NSRunningApplication sends a normal quit request without launching the app.
    # A canceled request or a process that does not exit must leave the install alone.
    swift - <<'SWIFT'
import AppKit
import Foundation

let identifiers: Set<String> = ["com.bardya.nosy", "com.bardya.lecturetranscriber"]
func running() -> [NSRunningApplication] {
    NSWorkspace.shared.runningApplications.filter {
        !$0.isTerminated && $0.bundleIdentifier.map(identifiers.contains) == true
    }
}
let apps = running()
for app in apps where !app.terminate() && !app.isTerminated {
    fputs("INSTALL BLOCKED: could not ask the running app to quit.\n", stderr)
    exit(1)
}
let deadline = Date().addingTimeInterval(30)
while !running().isEmpty && Date() < deadline {
    RunLoop.current.run(until: Date().addingTimeInterval(0.2))
}
guard running().isEmpty else {
    fputs("INSTALL BLOCKED: the app did not quit; installation was canceled.\n", stderr)
    exit(1)
}
SWIFT
    # Keep the old bundle until the staged replacement has been installed. If
    # the final move fails, restore it; never delete an unrestored backup.
    if [[ -e '/Applications/Nosy.app' || -L '/Applications/Nosy.app' ]]; then
        mv '/Applications/Nosy.app' "$INSTALL_STAGE/previous-Nosy.app"
        KEEP_INSTALL_STAGE=true
    fi
    if ! mv "$INSTALL_STAGE/Nosy.app" '/Applications/Nosy.app'; then
        if [[ -e "$INSTALL_STAGE/previous-Nosy.app" || -L "$INSTALL_STAGE/previous-Nosy.app" ]]; then
            if mv "$INSTALL_STAGE/previous-Nosy.app" '/Applications/Nosy.app'; then
                KEEP_INSTALL_STAGE=false
            fi
        fi
        printf 'INSTALL BLOCKED: could not install the staged bundle.\n' >&2
        exit 1
    fi
    KEEP_INSTALL_STAGE=false
    rm -rf '/Applications/Lecture Transcriber.app'
    printf 'Installed /Applications/Nosy.app\n'
fi
