#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
export BUILD_DIR="${BUILD_DIR:-$HOME/Library/Caches/Nosy Build r8llm/focused}"
source scripts/audio-shim.sh
mkdir -p "$BUILD_DIR/module-cache"
swiftc -D NOSY_UI_TEST -swift-version 6 -strict-concurrency=complete -parse-as-library \
    -target arm64-apple-macos14.0 -module-cache-path "$BUILD_DIR/module-cache" \
    "${AUDIO_SHIM[@]}" Sources/*.swift tests/LocalModelTests.swift -o "$BUILD_DIR/LocalModelTests"
"$BUILD_DIR/LocalModelTests" "$@"
