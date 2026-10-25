#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/paths.sh
source scripts/audio-shim.sh
python3 tests/InstallGuardTests.py
mkdir -p "$BUILD_DIR/module-cache"
clang -fobjc-arc -fmodules -target arm64-apple-macos14.0 tests/AudioExceptionsTests.m "$BUILD_DIR/AudioExceptions.o" -framework AVFoundation -framework Foundation -o "$BUILD_DIR/AudioExceptionsTests"
"$BUILD_DIR/AudioExceptionsTests"
BACKEND=(Sources/Core.swift Sources/AudioFiles.swift Sources/Models.swift)
swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library -target arm64-apple-macos14.0 \
    -module-cache-path "$BUILD_DIR/module-cache" "${BACKEND[@]}" tests/CoreTests.swift -o "$BUILD_DIR/CoreTests"
"$BUILD_DIR/CoreTests"
swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library -target arm64-apple-macos14.0 \
    -module-cache-path "$BUILD_DIR/module-cache" "${BACKEND[@]}" tests/BackendTests.swift -o "$BUILD_DIR/BackendTests"
"$BUILD_DIR/BackendTests"
swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library -target arm64-apple-macos14.0 \
    -module-cache-path "$BUILD_DIR/module-cache" "${BACKEND[@]}" Sources/Vocabulary*.swift Sources/SubjectCatalog.swift Sources/Transcriber.swift tests/TranscriberTests.swift -o "$BUILD_DIR/TranscriberTests"
swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library -target arm64-apple-macos14.0 \
    -module-cache-path "$BUILD_DIR/module-cache" "${BACKEND[@]}" Sources/Vocabulary*.swift Sources/SubjectCatalog.swift Sources/Transcriber.swift Sources/Summaries.swift tests/SummaryTests.swift -o "$BUILD_DIR/SummaryTests"
"$BUILD_DIR/SummaryTests"
"$BUILD_DIR/TranscriberTests"
swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library -target arm64-apple-macos14.0 \
    -module-cache-path "$BUILD_DIR/module-cache" "${BACKEND[@]}" Sources/Vocabulary*.swift Sources/SubjectCatalog.swift Sources/TranscriptBlocks.swift Sources/Transcriber.swift tests/VocabularyTests.swift -o "$BUILD_DIR/VocabularyTests"
"$BUILD_DIR/VocabularyTests"
swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library -target arm64-apple-macos14.0 \
    -module-cache-path "$BUILD_DIR/module-cache" "${BACKEND[@]}" Sources/AudioInputs.swift Sources/RecordingSource.swift \
    "${AUDIO_SHIM[@]}" Sources/CaptureMixer.swift Sources/MacAudioCapture.swift Sources/Recorder.swift tests/AudioCaptureTests.swift -o "$BUILD_DIR/AudioCaptureTests"
"$BUILD_DIR/AudioCaptureTests"
swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library -target arm64-apple-macos14.0 \
    -module-cache-path "$BUILD_DIR/module-cache" "${BACKEND[@]}" tests/AudioImportTests.swift -o "$BUILD_DIR/AudioImportTests"
"$BUILD_DIR/AudioImportTests"
swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library -target arm64-apple-macos14.0 \
    -module-cache-path "$BUILD_DIR/module-cache" Connector/MCPServer.swift Connector/TranscriptStore.swift \
    Sources/ClaudeConnector.swift tests/ConnectorTests.swift -o "$BUILD_DIR/ConnectorTests"
"$BUILD_DIR/ConnectorTests"
swiftc -swift-version 6 -strict-concurrency=complete -parse-as-library -target arm64-apple-macos14.0 \
    -module-cache-path "$BUILD_DIR/module-cache" "${BACKEND[@]}" Sources/MainControls.swift tests/MainControlsTests.swift -o "$BUILD_DIR/MainControlsTests"
"$BUILD_DIR/MainControlsTests"
swiftc -D NOSY_UI_TEST -swift-version 6 -strict-concurrency=complete -parse-as-library -target arm64-apple-macos14.0 \
    -module-cache-path "$BUILD_DIR/module-cache" "${AUDIO_SHIM[@]}" Sources/*.swift tests/LibraryTests.swift -o "$BUILD_DIR/LibraryTests"
"$BUILD_DIR/LibraryTests"
swiftc -D NOSY_UI_TEST -swift-version 6 -strict-concurrency=complete -parse-as-library -target arm64-apple-macos14.0 \
    -module-cache-path "$BUILD_DIR/module-cache" "${AUDIO_SHIM[@]}" Sources/*.swift tests/UITests.swift tests/MainWindowInteraction.swift tests/AppLifecycleTests.swift -o "$BUILD_DIR/UITests"
"$BUILD_DIR/UITests"
