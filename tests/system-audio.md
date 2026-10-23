# System audio recording

The mic menu's Source section offers Mic, Mac audio, and Both on macOS 14.4+.
Choices persist; starting/stopping and unpaused recording lock source changes.
Mac audio needs system audio recording consent, requested when the aggregate's
IO starts. Mic/Both also need microphone consent. Core Audio errors display a
banner with an Open Mac Audio Settings button (`Privacy_AudioCapture`).

Mic uses the existing pinned AVAudioEngine path. Mac audio uses a private global
process tap excluding Nosy's Core Audio process object, a private tap-only
aggregate with drift compensation, and an input IOProc. It never changes a default
device, mutes another app, or opens an audio playback path. Both runs the pinned
mic alongside the tap, converts each to float mono 16 kHz using AVAudioConverter,
and places samples on a bounded host-clock timeline. Consecutive timestamps
correct small clock drift; late buffers cannot accumulate or replay after gaps.
The mixer balances speech levels with bounded RMS gains and a peak limiter before
writing Int16. All sources share the crash-safe raw PCM writer, five-second sync,
WAV finalization, boost, and transcription pipeline.

The mixer waits at least 200 ms for mic/tap scheduling jitter (longer for low-rate
microphone buffers) and drains that tail on pause
and stop. Pause discards converter history; resume and wake start a fresh timeline.
Mic configuration changes retain the existing restart/fallback and pinning logic.
Source changes while paused restore the prior source if the new one fails.

The tap watchdog checks HAL object liveness, its reader, and format changes.
Zero-valued buffers are valid heartbeats. No buffers are also valid silence,
even when a meeting app keeps output IO open. Ten seconds without callbacks
quietly rearms the tap; an invalid HAL object or format raises the source warning.
Mic-only silence warnings and the four-second missing-mic-buffer watchdog remain.

## Automated checks

`tests/run_unit.sh` includes streaming conversion at 44.1/48/96 kHz, interleaved
and discrete-channel downmixing, gain balance, limiting, invalid samples, silent
PCM, partial final buffers, timestamp drift, late buffers, watchdog policy, source
state guards, preference persistence, and source labels. `tests/run_pipeline.sh`
exercises the unchanged real Whisper/boost/import/compression/retry pipeline.

A bundled-app headless mode captures without transcribing or playing anything:

```sh
NOSY_SUPPORT_DIR="$PWD/build/capture-support" \
NOSY_TRANSCRIPTS_DIR="$PWD/build/capture-transcripts" \
build/Nosy.app/Contents/MacOS/Nosy --headless-capture 5 macAudio \
    "$PWD/build/silent.wav" --exercise-lifecycle
```

The destination must not exist. Source arguments are `mic`, `macAudio`, or `both`.
The optional lifecycle flag verifies rejection of active source changes, pause
without writes, paused source reconstruction, resume, and the wake recovery path.
It fails on recorder errors or stall events. It does not put the Mac to sleep.

## Verification on 2026-10-23

- macOS 27.0.1, Apple Silicon; Swift 6 strict concurrency, macOS 14.0 target.
- `./build.sh`, `tests/run_unit.sh`, `tests/run_pipeline.sh`, full typecheck passed.
- Silent Mac capture: 5.14 s, 16 kHz mono Int16 WAV, every sample zero, no stall.
- Silent lifecycle capture: 5.13 s of zero samples, no stall or paused writes.
- Final extended silent capture: 12.13 s, every sample zero; Settings help emitted
  after ten seconds, with no stall warning.
- Both: live mic + tap capture passed, including lifecycle checks; no audio played.
- Builds used isolated `build/system-audio` output; no installed app was changed.

Still needs manual verification: an audible Zoom/Teams/YouTube session,
long-running physical clock drift, actual lid sleep/wake and device unplugging,
macOS 14.4 runtime, and first-time consent denial/revocation. There is no public
Core Audio permission preflight API. Some macOS versions silently deliver zeros
on denied consent, indistinguishable from real silence; explicit OSStatus errors
have the Settings recovery banner. After ten seconds without a nonzero Mac
sample, a neutral silence banner also offers Settings recovery, explaining what
to do if audio is playing or consent was denied. It clears when samples arrive,
never claims silence proves denial, and never changes the stall state. No private
TCC APIs are used.
