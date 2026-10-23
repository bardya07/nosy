#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/common.sh
wait_for_model
prepare_test_dirs
RECORD_PID=''
cleanup() {
    if [[ -n "$RECORD_PID" ]]; then kill -9 "$RECORD_PID" 2>/dev/null || true; wait "$RECORD_PID" 2>/dev/null || true; fi
    rm -rf "$TEST_ROOT"
}
trap cleanup EXIT
"$APP" --headless-record 120 'Crash Test' 'Interrupted' > "$TEST_ROOT/record.log" 2>&1 &
RECORD_PID=$!
READY=0
for attempt in {1..60}; do
    if ! kill -0 "$RECORD_PID" 2>/dev/null; then
        set +e
        wait "$RECORD_PID"
        CODE=$?
        set -e
        RECORD_PID=''
        cat "$TEST_ROOT/record.log"
        if [[ "$CODE" == 77 ]]; then printf 'CRASH SKIPPED: microphone permission denied or restricted\n'; exit 0; fi
        printf 'CRASH FAIL: recording exited with status %s\n' "$CODE" >&2; exit 1
    fi
    if python3 - <<'PY'
import os, pathlib, sys
audio = pathlib.Path(os.environ['NOSY_SUPPORT_DIR'])/'audio'
sys.exit(0 if any(p.stat().st_size >= 7*32000 for p in audio.glob('*.pcm')) else 1)
PY
    then READY=1; break; fi
    sleep 0.5
done
if [[ "$READY" != 1 ]]; then
    if [[ -z $(find "$NOSY_SUPPORT_DIR/audio" -name '*.json' -print -quit) ]]; then
        printf 'CRASH SKIPPED: microphone permission was not granted within 30 seconds\n'; exit 0
    fi
    cat "$TEST_ROOT/record.log"
    printf 'CRASH FAIL: microphone produced no audio\n' >&2; exit 1
fi
kill -9 "$RECORD_PID"
wait "$RECORD_PID" 2>/dev/null || true
RECORD_PID=''
"$APP" --headless-recover
ID=$(python3 - <<'PY'
import json, os, pathlib, wave
audio = pathlib.Path(os.environ['NOSY_SUPPORT_DIR'])/'audio'
records = list(audio.glob('*.json')); assert len(records) == 1
r = json.loads(records[0].read_text())
assert r['status'] == 'failed' and r['error'] == 'App closed unexpectedly'
assert not (audio/(r['id']+'.pcm')).exists()
with wave.open(str(audio/(r['id']+'.wav'))) as w:
    assert w.getframerate() == 16000 and w.getnchannels() == 1 and w.getsampwidth() == 2
    assert w.getnframes() >= 7*16000
print(r['id'])
PY
)
afinfo "$NOSY_SUPPORT_DIR/audio/$ID.wav" > "$TEST_ROOT/afinfo.txt"
"$APP" --headless-transcribe "$ID"
python3 - <<'PY'
import json, os, pathlib
a = pathlib.Path(os.environ['NOSY_SUPPORT_DIR'])/'audio'
r = json.loads(next(a.glob('*.json')).read_text())
assert r['status'] == 'done' and pathlib.Path(r['transcriptPath']).is_file()
assert '## Transcript' in pathlib.Path(r['transcriptPath']).read_text()
print('CRASH PASS: real microphone, kill -9, recovery WAV + sidecar, Whisper Retry + markdown')
PY
