#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/paths.sh
mkdir -p "$BUILD_DIR/module-cache"
BACKEND=(Sources/Core.swift Sources/AudioFiles.swift Sources/Models.swift)
swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library -target arm64-apple-macos26.0 \
    -module-cache-path "$BUILD_DIR/module-cache" "${BACKEND[@]}" tests/CoreTests.swift -o "$BUILD_DIR/CoreTests"
"$BUILD_DIR/CoreTests"
swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library -target arm64-apple-macos26.0 \
    -module-cache-path "$BUILD_DIR/module-cache" "${BACKEND[@]}" tests/BackendTests.swift -o "$BUILD_DIR/BackendTests"
"$BUILD_DIR/BackendTests"
swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library -target arm64-apple-macos26.0 \
    -module-cache-path "$BUILD_DIR/module-cache" "${BACKEND[@]}" Sources/Transcriber.swift tests/TranscriberTests.swift -o "$BUILD_DIR/TranscriberTests"
"$BUILD_DIR/TranscriberTests"
