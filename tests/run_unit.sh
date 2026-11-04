#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/paths.sh
source scripts/audio-shim.sh
AUDIO_SHIM+=(-F "$PWD/vendor/sparkle" -framework Sparkle -Xlinker -rpath -Xlinker "$PWD/vendor/sparkle")
python3 tests/InstallGuardTests.py
mkdir -p "$BUILD_DIR/module-cache"
clang -fobjc-arc -fmodules -target arm64-apple-macos14.0 tests/AudioExceptionsTests.m "$BUILD_DIR/AudioExceptions.o" -framework AVFoundation -framework CoreAudio -framework Foundation -o "$BUILD_DIR/AudioExceptionsTests"
swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library -target arm64-apple-macos14.0 \
    -module-cache-path "$BUILD_DIR/module-cache" Sources/FeatureGates.swift tests/FeatureGatesTests.swift -o "$BUILD_DIR/FeatureGatesTests"
"$BUILD_DIR/FeatureGatesTests"
swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library -target arm64-apple-macos14.0 \
    -module-cache-path "$BUILD_DIR/module-cache" Sources/RecordingGuidance.swift tests/RecordingGuidanceTests.swift -o "$BUILD_DIR/RecordingGuidanceTests"
"$BUILD_DIR/RecordingGuidanceTests"
"$BUILD_DIR/AudioExceptionsTests"
swiftc -D NOSY_UI_TEST -swift-version 6 -strict-concurrency=complete -parse-as-library -target arm64-apple-macos14.0 \
    -module-cache-path "$BUILD_DIR/module-cache" "${AUDIO_SHIM[@]}" Sources/*.swift tests/CoreTests.swift -o "$BUILD_DIR/CoreTests"
"$BUILD_DIR/CoreTests"
swiftc -D NOSY_UI_TEST -swift-version 6 -strict-concurrency=complete -parse-as-library -target arm64-apple-macos14.0 \
    -module-cache-path "$BUILD_DIR/module-cache" "${AUDIO_SHIM[@]}" Sources/*.swift tests/BackendTests.swift -o "$BUILD_DIR/BackendTests"
"$BUILD_DIR/BackendTests"
swiftc -D NOSY_UI_TEST -swift-version 6 -strict-concurrency=complete -parse-as-library -target arm64-apple-macos14.0 \
    -module-cache-path "$BUILD_DIR/module-cache" "${AUDIO_SHIM[@]}" Sources/*.swift tests/TranscriberTests.swift -o "$BUILD_DIR/TranscriberTests"
swiftc -D NOSY_UI_TEST -swift-version 6 -strict-concurrency=complete -parse-as-library -target arm64-apple-macos14.0 \
    -module-cache-path "$BUILD_DIR/module-cache" "${AUDIO_SHIM[@]}" Sources/*.swift tests/SummaryTests.swift -o "$BUILD_DIR/SummaryTests"
"$BUILD_DIR/SummaryTests"
swiftc -D NOSY_UI_TEST -swift-version 6 -strict-concurrency=complete -parse-as-library -target arm64-apple-macos14.0 \
    -module-cache-path "$BUILD_DIR/module-cache" "${AUDIO_SHIM[@]}" Sources/*.swift tests/KeyMomentsTests.swift -o "$BUILD_DIR/KeyMomentsTests"
"$BUILD_DIR/KeyMomentsTests"
swiftc -D NOSY_UI_TEST -swift-version 6 -strict-concurrency=complete -parse-as-library -target arm64-apple-macos14.0 \
    -module-cache-path "$BUILD_DIR/module-cache" "${AUDIO_SHIM[@]}" Sources/*.swift tests/AIFeatureSchedulingTests.swift -o "$BUILD_DIR/AIFeatureSchedulingTests"
"$BUILD_DIR/AIFeatureSchedulingTests"
swiftc -D NOSY_UI_TEST -swift-version 6 -strict-concurrency=complete -parse-as-library -target arm64-apple-macos14.0 \
    -module-cache-path "$BUILD_DIR/module-cache" "${AUDIO_SHIM[@]}" Sources/*.swift tests/LocalModelTests.swift -o "$BUILD_DIR/LocalModelTests"
"$BUILD_DIR/LocalModelTests"
swiftc -D NOSY_UI_TEST -swift-version 6 -strict-concurrency=complete -parse-as-library -target arm64-apple-macos14.0 \
    -module-cache-path "$BUILD_DIR/module-cache" "${AUDIO_SHIM[@]}" Sources/*.swift tests/TranscriptsSettingsTests.swift -o "$BUILD_DIR/TranscriptsSettingsTests"
"$BUILD_DIR/TranscriptsSettingsTests"
"$BUILD_DIR/TranscriberTests"
swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library -target arm64-apple-macos14.0 \
    -module-cache-path "$BUILD_DIR/module-cache" Sources/TranscriptionQuality.swift tests/TranscriptionQualityTests.swift -o "$BUILD_DIR/TranscriptionQualityTests"
"$BUILD_DIR/TranscriptionQualityTests"
swiftc -D NOSY_UI_TEST -swift-version 6 -strict-concurrency=complete -parse-as-library -target arm64-apple-macos14.0 \
    -module-cache-path "$BUILD_DIR/module-cache" "${AUDIO_SHIM[@]}" Sources/*.swift tests/VocabularyTests.swift -o "$BUILD_DIR/VocabularyTests"
"$BUILD_DIR/VocabularyTests"
swiftc -D NOSY_UI_TEST -swift-version 6 -strict-concurrency=complete -parse-as-library -target arm64-apple-macos14.0 \
    -module-cache-path "$BUILD_DIR/module-cache" "${AUDIO_SHIM[@]}" Sources/*.swift tests/AudioCaptureTests.swift -o "$BUILD_DIR/AudioCaptureTests"
"$BUILD_DIR/AudioCaptureTests"
swiftc -D NOSY_UI_TEST -swift-version 6 -strict-concurrency=complete -parse-as-library -target arm64-apple-macos14.0 \
    -module-cache-path "$BUILD_DIR/module-cache" "${AUDIO_SHIM[@]}" Sources/*.swift tests/AudioImportTests.swift -o "$BUILD_DIR/AudioImportTests"
"$BUILD_DIR/AudioImportTests"
swiftc -D NOSY_UI_TEST -swift-version 6 -strict-concurrency=complete -parse-as-library -target arm64-apple-macos14.0 \
    -module-cache-path "$BUILD_DIR/module-cache" "${AUDIO_SHIM[@]}" Sources/*.swift Connector/MCPServer.swift Connector/TranscriptStore.swift \
    tests/ConnectorTests.swift -o "$BUILD_DIR/ConnectorTests"
"$BUILD_DIR/ConnectorTests"
swiftc -D NOSY_UI_TEST -swift-version 6 -strict-concurrency=complete -parse-as-library -target arm64-apple-macos14.0 \
    -module-cache-path "$BUILD_DIR/module-cache" "${AUDIO_SHIM[@]}" Sources/*.swift tests/MainControlsTests.swift -o "$BUILD_DIR/MainControlsTests"
"$BUILD_DIR/MainControlsTests"
swiftc -D NOSY_UI_TEST -swift-version 6 -strict-concurrency=complete -parse-as-library -target arm64-apple-macos14.0 \
    -module-cache-path "$BUILD_DIR/module-cache" "${AUDIO_SHIM[@]}" Sources/*.swift tests/LibraryTests.swift -o "$BUILD_DIR/LibraryTests"
"$BUILD_DIR/LibraryTests"
swiftc -D NOSY_UI_TEST -swift-version 6 -strict-concurrency=complete -parse-as-library -target arm64-apple-macos14.0 \
    -module-cache-path "$BUILD_DIR/module-cache" "${AUDIO_SHIM[@]}" Sources/*.swift tests/UITests.swift tests/MainWindowInteraction.swift tests/AppLifecycleTests.swift -o "$BUILD_DIR/UITests"
"$BUILD_DIR/UITests"
