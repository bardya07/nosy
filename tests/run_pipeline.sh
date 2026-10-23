#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
source scripts/paths.sh
# Use the current backend even when another engineer's UI rewrite is incomplete.
if [[ -z "${NOSY_TEST_APP:-}" ]]; then
    mkdir -p "$BUILD_DIR/module-cache"
    swiftc -O -swift-version 6 -strict-concurrency=complete -parse-as-library -target arm64-apple-macos26.0 \
        -module-cache-path "$BUILD_DIR/module-cache" \
        Sources/Core.swift Sources/AudioFiles.swift Sources/Models.swift Sources/AudioInputs.swift \
        Sources/Recorder.swift Sources/Transcriber.swift Sources/Headless.swift tests/HeadlessMain.swift \
        -o "$BUILD_DIR/NosyHeadless"
    export NOSY_TEST_APP="$BUILD_DIR/NosyHeadless"
fi
source tests/common.sh
export NOSY_TEST_AAC=1
if [[ "$APP" == "$BUILD_DIR/NosyHeadless" ]] && ! "$APP" --test-aac-capability; then
    export NOSY_TEST_AAC=0
    printf 'AAC SKIPPED: sandbox exposes no AAC codecs; checking WAV preservation and PCM-in-M4A Retry.\n'
fi
wait_for_model
prepare_test_dirs
trap 'rm -rf "$TEST_ROOT"' EXIT
export NOSY_REAL_CLI="$REAL_WHISPER" NOSY_ARGS_LOG="$TEST_ROOT/arguments.txt"
export NOSY_CPU_MARKER="$TEST_ROOT/cpu-fallback" NOSY_GPU_LOG="$TEST_ROOT/gpu.log"
cat > "$TEST_ROOT/whisper-wrapper" <<'SH'
#!/bin/bash
set -uo pipefail
printf '%s\n' "$@" > "$NOSY_ARGS_LOG"
if [[ -f "$NOSY_CPU_MARKER" ]]; then exec "$NOSY_REAL_CLI" -ng "$@"; fi
"$NOSY_REAL_CLI" "$@" 2> "$NOSY_GPU_LOG"
CODE=$?
cat "$NOSY_GPU_LOG" >&2
if [[ "$CODE" == 134 ]] && grep -qE 'GGML_ASSERT\(buffer\)' "$NOSY_GPU_LOG"; then
    touch "$NOSY_CPU_MARKER"
    exec "$NOSY_REAL_CLI" -ng "$@"
fi
exit "$CODE"
SH
chmod +x "$TEST_ROOT/whisper-wrapper"
export NOSY_WHISPER_CLI="$TEST_ROOT/whisper-wrapper"
say -v 'Samantha' -r 155 -o "$TEST_ROOT/lecture.aiff" \
    'Today we will discuss glycolysis and cellular metabolism. Glucose is converted into pyruvate through a series of enzyme reactions. Phosphofructokinase is an important regulatory enzyme. The pathway produces ATP and NADH. Remember that energy balance controls the rate of glycolysis in every living cell.' 2> "$TEST_ROOT/say.log"
afconvert -f WAVE -d LEI16@16000 -c 1 "$TEST_ROOT/lecture.aiff" "$TEST_ROOT/speech.wav"
export NOSY_TEST_FIXTURE=lecture
if ! python3 - "$TEST_ROOT/speech.wav" <<'PY'
import sys, wave
with wave.open(sys.argv[1]) as w: sys.exit(0 if w.getnframes() else 1)
PY
then
    if ! grep -qE 'sandbox_extension_issue_file failed' "$TEST_ROOT/say.log"; then
        cat "$TEST_ROOT/say.log" >&2
        printf 'FAIL: say generated no speech\n' >&2; exit 1
    fi
    # In restricted runners macOS refuses SpeechSynthesisServer extensions.
    # Still exercise real recognition, using Homebrew whisper.cpp's speech sample.
    export NOSY_TEST_FIXTURE=jfk
    SAMPLE="$(dirname "$(dirname "$(python3 -c 'import os; print(os.path.realpath(os.environ["NOSY_REAL_CLI"]))')")")/share/whisper.cpp/jfk.wav"
    python3 - "$SAMPLE" "$TEST_ROOT/speech.wav" <<'PY'
import sys, wave
with wave.open(sys.argv[1]) as source:
    params = source.getparams(); pcm = source.readframes(source.getnframes())
with wave.open(sys.argv[2], 'wb') as target:
    target.setparams(params); target.writeframes(pcm * 2)
PY
    printf 'PIPELINE NOTE: sandbox blocks say; using the installed whisper.cpp JFK speech fixture (22 s).\n'
fi
python3 - "$TEST_ROOT" <<'PY'
import json, os, pathlib, sys, wave
root = pathlib.Path(sys.argv[1])
with wave.open(str(root/'speech.wav')) as w:
    assert w.getframerate() == 16000 and w.getnchannels() == 1 and w.getsampwidth() == 2
    pcm = w.readframes(w.getnframes())
assert 15 <= len(pcm)/32000 <= 30, f'Expected ~20 seconds, got {len(pcm)/32000}'
audio = pathlib.Path(os.environ['NOSY_SUPPORT_DIR'])/'audio'
for id in ['20261021-120000', '20261021-120001']:
    (audio/f'{id}.pcm').write_bytes(pcm)
    (audio/f'{id}.json').write_text(json.dumps(dict(id=id, lecture='Biochemistry', session='Energy',
        startedAt='2026-10-21T19:00:00Z', status='recording')))
PY
"$APP" --headless-transcribe 20261021-120000
# A missing executable must preserve the audio and offer a usable retry.
if NOSY_WHISPER_CLI=/nonexistent/whisper-cli "$APP" --headless-transcribe 20261021-120001 >"$TEST_ROOT/missing.log" 2>&1; then
    printf 'FAIL: missing CLI unexpectedly succeeded\n' >&2; exit 1
fi
python3 - <<'PY'
import json, os, pathlib
a = pathlib.Path(os.environ['NOSY_SUPPORT_DIR'])/'audio'
r = json.loads((a/'20261021-120001.json').read_text())
assert r['status'] == 'failed' and 'whisper-cli is missing' in r['error']
assert (a/'20261021-120001.wav').exists()
PY
printf 'glycolysis\n NADH   phosphofructokinase\npyruvate ATP\n' > "$NOSY_TRANSCRIPTS_DIR/Biochemistry/vocab.txt"
"$APP" --headless-transcribe 20261021-120001
if [[ "$NOSY_TEST_AAC" == 1 ]]; then
    afinfo "$NOSY_SUPPORT_DIR/audio/20261021-120000.m4a" > "$TEST_ROOT/afinfo.txt"
else
    afinfo "$NOSY_SUPPORT_DIR/audio/20261021-120000.wav" > "$TEST_ROOT/afinfo.txt"
fi
python3 - "$TEST_ROOT" <<'PY'
import json, os, pathlib, re, sys, wave
root = pathlib.Path(sys.argv[1]); audio = pathlib.Path(os.environ['NOSY_SUPPORT_DIR'])/'audio'
transcripts = pathlib.Path(os.environ['NOSY_TRANSCRIPTS_DIR'])/'Biochemistry'
for id, filename in [('20261021-120000','Energy.md'), ('20261021-120001','Energy-2.md')]:
    r = json.loads((audio/f'{id}.json').read_text()); assert r['status'] == 'done' and not r.get('error')
    text = (transcripts/filename).read_text()
    assert text.startswith('# Biochemistry — Energy\n\n- Date: 2026-10-21\n- Started: ')
    assert re.search(r'- Started: \d{2}:\d{2}\n- Length: 1 min\n\n## Transcript\n\n', text)
    expected = ['glycolysis', 'glucose', 'pyruvate', 'enzyme', 'nadh'] if os.environ['NOSY_TEST_FIXTURE'] == 'lecture' else ['ask', 'country', 'americans', 'fellow', 'you']
    words = [word for word in expected if word in text.lower()]
    assert len(words) >= 3, text
    assert pathlib.Path(r['transcriptPath']) == transcripts/filename
    assert not (audio/f'{id}.pcm').exists()
    if os.environ['NOSY_TEST_AAC'] == '1':
        assert (audio/f'{id}.m4a').stat().st_size > 0, 'Successful transcript must compress audio'
        assert not (audio/f'{id}.wav').exists(), 'Verified compression must remove WAV'
    else:
        with wave.open(str(audio/f'{id}.wav')) as w:
            assert w.getframerate() == 16000 and w.getnchannels() == 1 and w.getsampwidth() == 2
assert not list(audio.glob('.whisper-*')), 'Temporary outputs leaked'
args = (root/'arguments.txt').read_text().splitlines()
assert args[args.index('--prompt')+1] == 'glycolysis NADH phosphofructokinase pyruvate ATP'
assert args[args.index('-l')+1] == 'en' and int(args[args.index('-t')+1]) >= 4
assert args[args.index('-mc')+1] == '0'
if (pathlib.Path(os.environ['NOSY_SUPPORT_DIR'])/'models/ggml-silero-v5.1.2.bin').exists():
    assert '--vad' in args and '-vm' in args
print('PIPELINE TRANSCRIPTION PASS: real Whisper, with/without vocab, audio + markdown, unique naming, failure + Retry (' + os.environ['NOSY_TEST_FIXTURE'] + ' fixture)')
PY
# Exercise import from an AAC container at a different rate and channel count.
# The source is say's speech, or the existing sandbox speech fallback above.
afconvert -f AIFF -d BEI16@44100 -c 2 "$TEST_ROOT/speech.wav" "$TEST_ROOT/import.aiff"
if [[ "$NOSY_TEST_AAC" == 1 ]]; then
    afconvert -f m4af -d 'aac ' -b 96000 "$TEST_ROOT/import.aiff" "$TEST_ROOT/import.m4a"
else
    afconvert -f m4af -d LEI16 "$TEST_ROOT/import.aiff" "$TEST_ROOT/import.m4a"
fi
afinfo "$TEST_ROOT/import.m4a" > "$TEST_ROOT/import-info.txt"
grep -qE '44100' "$TEST_ROOT/import-info.txt"
"$APP" --headless-import "$TEST_ROOT/import.m4a" 'Imported Lecture' 'Imported Session' > "$TEST_ROOT/import.log"
cat "$TEST_ROOT/import.log"
ID=$(python3 - "$TEST_ROOT" <<'PY'
import json, os, pathlib, sys
root = pathlib.Path(sys.argv[1]); audio = pathlib.Path(os.environ['NOSY_SUPPORT_DIR'])/'audio'
records = [json.loads(p.read_text()) for p in audio.glob('*.json')]
r, = [r for r in records if r['lecture'] == 'Imported Lecture']
assert r['status'] == 'done' and not r.get('error')
text = pathlib.Path(r['transcriptPath']).read_text().lower()
expected = ['glycolysis', 'glucose', 'pyruvate', 'enzyme', 'nadh'] if os.environ['NOSY_TEST_FIXTURE'] == 'lecture' else ['ask', 'country', 'americans', 'fellow', 'you']
assert sum(word in text for word in expected) >= 3, text
if os.environ['NOSY_TEST_AAC'] == '1':
    assert (audio/(r['id']+'.m4a')).stat().st_size > 0
    assert not (audio/(r['id']+'.wav')).exists()
else:
    assert (audio/(r['id']+'.wav')).exists(), 'Unavailable AAC encoder must preserve WAV'
assert not (audio/(r['id']+'.pcm')).exists()
assert ('IMPORT PASS: ' + r['transcriptPath']) in (root/'import.log').read_text()
print(r['id'])
PY
)
if [[ "$NOSY_TEST_AAC" == 0 ]]; then
    afconvert -f m4af -d LEI16 "$NOSY_SUPPORT_DIR/audio/$ID.wav" "$NOSY_SUPPORT_DIR/audio/$ID.m4a"
    rm "$NOSY_SUPPORT_DIR/audio/$ID.wav"
fi
"$APP" --headless-transcribe "$ID"
python3 - "$ID" <<'PY'
import json, os, pathlib, sys
audio = pathlib.Path(os.environ['NOSY_SUPPORT_DIR'])/'audio'; id = sys.argv[1]
r = json.loads((audio/(id+'.json')).read_text())
assert r['status'] == 'done' and not r.get('error')
assert pathlib.Path(r['transcriptPath']).name == 'Imported Session-2.md'
text = pathlib.Path(r['transcriptPath']).read_text().lower()
expected = ['glycolysis', 'glucose', 'pyruvate', 'enzyme', 'nadh'] if os.environ['NOSY_TEST_FIXTURE'] == 'lecture' else ['ask', 'country', 'americans', 'fellow', 'you']
assert sum(word in text for word in expected) >= 3, text
assert (audio/(id+'.m4a')).stat().st_size > 0
assert (audio/(id+'.wav')).exists() == (os.environ['NOSY_TEST_AAC'] == '0')
assert not (audio/(id+'.pcm')).exists()
assert not list(audio.glob('.whisper-*'))
mode = 'AAC compression' if os.environ['NOSY_TEST_AAC'] == '1' else 'WAV preservation (AAC unavailable)'
print('PIPELINE PASS: real Whisper, import 44.1 kHz stereo M4A, resampling, ' + mode + ', Retry from M4A, vocabulary, failure safety, unique markdown')
PY
if [[ -f "$NOSY_CPU_MARKER" ]]; then printf 'PIPELINE NOTE: Metal allocation failed in the restricted runner; real Whisper ran on CPU via the test CLI override.\n'; fi
