#!/bin/bash
# Source from a test after changing to the repository root.
source scripts/paths.sh
APP="${NOSY_TEST_APP:-$BUILD_DIR/Nosy.app/Contents/MacOS/Nosy}"
[[ -x "$APP" ]] || { printf 'Build the app with ./build.sh first.\n' >&2; exit 1; }
REAL_MODEL="$HOME/Library/Application Support/Nosy/models/ggml-large-v3-turbo.bin"
REAL_VAD="$HOME/Library/Application Support/Nosy/models/ggml-silero-v5.1.2.bin"
REAL_WHISPER="${NOSY_WHISPER_CLI:-$BUILD_DIR/Nosy.app/Contents/Helpers/whisper-cli}"
[[ -x "$REAL_WHISPER" ]] || { printf 'Build the bundled speech engine and app first: ./scripts/build-whisper.sh && ./build.sh\n' >&2; exit 1; }
printf 'TEST ENGINE: %s\n' "$REAL_WHISPER"
wait_for_model() {
    # Published size of the specified ggml large-v3-turbo model. Read only.
    while [[ ! -f "$REAL_MODEL" ]] || [[ $(stat -f %z "$REAL_MODEL") -lt 1624555275 ]]; do
        printf 'WAITING: large-v3-turbo model is still downloading; retrying in 15 seconds.\n'
        sleep 15
    done
}
prepare_test_dirs() {
    TEST_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/nosy-test.XXXXXX")
    export NOSY_SUPPORT_DIR="$TEST_ROOT/support"
    export NOSY_TRANSCRIPTS_DIR="$TEST_ROOT/transcripts"
    export NOSY_WHISPER_CLI="$REAL_WHISPER"
    mkdir -p "$NOSY_SUPPORT_DIR/audio" "$NOSY_SUPPORT_DIR/models" "$NOSY_TRANSCRIPTS_DIR"
    ln -s "$REAL_MODEL" "$NOSY_SUPPORT_DIR/models/ggml-large-v3-turbo.bin"
    if [[ -f "$REAL_VAD" ]]; then ln -s "$REAL_VAD" "$NOSY_SUPPORT_DIR/models/ggml-silero-v5.1.2.bin"; fi
}
