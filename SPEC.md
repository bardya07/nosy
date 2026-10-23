# Build spec: "Nosy" (native macOS app)

Historical development specification. The app has since gained a transcript library, queue, onboarding, pause, audio import/compression, and other features. See README.md for current requirements and usage; Sources/ is authoritative for current behavior. Paths and UI details below describe the original design.

## Environment
- Apple Silicon Mac, macOS 26 or later, and a compatible Xcode Swift 6 toolchain and macOS SDK. No Xcode project — build with `swiftc` from a shell script.
- whisper.cpp installed via Homebrew: `/opt/homebrew/bin/whisper-cli` (resolve also `/usr/local/bin/whisper-cli`).
- Model: `~/Library/Application Support/Nosy/models/ggml-large-v3-turbo.bin`
- Optional VAD model: `~/Library/Application Support/Nosy/models/ggml-silero-v5.1.2.bin` — if present, pass `--vad -vm <path>`.
- Signing: set `NOSY_CODESIGN_IDENTITY` to a local signing identity for a stable signature across rebuilds. Default and fallback: ad-hoc (`-`).
- Language is always English (`-l en`).

## Layout
```
Sources/Core.swift         pure logic, no UI (naming, sanitizing, WAV header, markdown, paragraphing, retention, recovery scan, paths)
Sources/Recorder.swift     AVAudioEngine capture → raw PCM file, level metering, silence detection, device-change handling
Sources/Transcriber.swift  runs whisper-cli via Process, builds the .md
Sources/AppModel.swift     @MainActor ObservableObject state machine, notifications, sleep prevention, recovery
Sources/App.swift          SwiftUI App: main window + MenuBarExtra + AppDelegate (quit protection)
Resources/Info.plist
Resources/AppIcon.icns     generate with a small script (simple waveform/mic glyph on a rounded square); optional, skip if it fights you
build.sh                   compile, bundle, sign, install to /Applications/Nosy.app
tests/                     see "Tests"
```
Bundle id `com.bardya.nosy`, name "Nosy", min macOS 26.0, arm64. Info.plist must include `NSMicrophoneUsageDescription` ("Nosy records lectures so they can be transcribed on this Mac.") and `LSApplicationCategoryType` public.app-category.education. Not sandboxed.

## Paths (all overridable by env vars for tests: `NOSY_TRANSCRIPTS_DIR`, `NOSY_SUPPORT_DIR`, `NOSY_WHISPER_CLI`)
- Transcripts root: `~/Desktop/Lecture Transcripts/` → `<Lecture>/<Session>.md`
- Support: `~/Library/Application Support/Nosy/` with `models/`, `audio/`
- Create folders as needed (lecture folder created at Start).

## Names
- Sanitize lecture and session: trim; replace `/ \ : * ? " < > |` and control chars with `-`; collapse whitespace; max 80 chars; reject empty and names that are only dots.
- Unique transcript path: `<Session>.md`, then `<Session>-2.md`, `-3`, … Never overwrite.

## Recording (crash-safe by design)
- Check mic permission with `AVCaptureDevice.authorizationStatus(for: .audio)`; request if notDetermined; if denied, show an error with a button that opens `x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone`.
- Before starting, check free space on the support volume; if < 2 GB, warn (alert with Continue / Cancel) and notify.
- Capture with `AVAudioEngine` input node tap; convert with `AVAudioConverter` to 16 kHz mono Int16 little-endian; append raw bytes to `audio/<id>.pcm` via FileHandle, `synchronize()` at least every ~5 s. `<id>` = `yyyyMMdd-HHmmss`.
- Sidecar `audio/<id>.json` (Codable): id, lecture, session, startedAt, endedAt?, status (`recording|transcribing|done|failed`), transcriptPath?, error?. Written atomically on every status change.
- Level: RMS of each buffer → dBFS published to UI (~10 Hz is fine).
- Silence: if level stays below −50 dBFS for 60 continuous seconds → one notification + in-window warning "Mic hears nothing — check your input". Clears when sound returns; can fire again after a new 60 s episode.
- `AVAudioEngineConfigurationChange` (device switched/unplugged): try to restart the engine and keep appending to the same file; if restart fails → status failed → notify "Recording stopped unexpectedly" (audio so far is kept and can be transcribed via Retry).
- Any other engine/write error → same failure path.
- Duration = pcm bytes / 32000 seconds (use this, not wall clock, everywhere).

## Stop → transcription (automatic)
1. Stop engine, close file, status `transcribing`.
2. Write `audio/<id>.wav` = 44-byte WAV header + PCM (stream copy, don't load whole file into memory), then delete the `.pcm`.
3. Run whisper-cli off the main thread: `-m <model> -f <wav> -l en -otxt -of <tmpbase> -np -t <performance core count, min 4>` plus `--prompt <vocab>` if `<Lecture folder>/vocab.txt` exists (read, collapse whitespace, cap at ~600 chars) plus VAD flags if the VAD model exists. Capture stderr for errors.
4. Build markdown:
```
# <Lecture> — <Session>

- Date: yyyy-MM-dd
- Started: HH:mm
- Length: <N> min        (round, min 1)

## Transcript

<paragraphs>
```
   Paragraphing: whisper txt has one segment per line. Trim lines, drop empty lines and pure non-speech markers like `[BLANK_AUDIO]`, `[Music]`, `(silence)`. Join with spaces; start a new paragraph after a segment ending in `.?!` once the current paragraph ≥ 600 chars.
   If the transcript is empty, still write the file with `_No speech detected._`.
5. Write to the unique path (atomic write), status `done`, keep the `.wav` for retention, delete tmp txt.
6. Notify "Transcript saved — <Lecture> · <Session>"; clicking it reveals the file in Finder. Window shows "Saved · Show in Finder".
- On failure: status `failed`, keep wav, notify "Transcription failed", window shows the error (last ~300 chars of stderr) + **Retry** button (re-runs step 3–6 on the existing wav).
- Missing whisper-cli or model: checked at launch (banner in window) and before transcribing (fail with clear message, audio kept, Retry available).

## Recovery (on launch)
- Scan `audio/*.json`. Any with status `recording` or `transcribing` (app died) → convert any `.pcm` to `.wav` (header from actual byte length), mark `failed` with error "App closed unexpectedly", and show a banner: "Unfinished lecture found: <Lecture> · <Session> (N min) — Transcribe now / Dismiss". Transcribe now = Retry path. Dismiss keeps audio (retention handles it).
- Multiple → handle the most recent in the banner; list count ("+2 more") and process them one at a time.

## Retention
- On launch and after each successful transcription: delete `audio/<id>.*` where status is `done` and startedAt older than 14 days. Never delete `failed`/unfinished audio automatically.

## Sleep prevention
- `ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled, .userInitiated], reason:)` from Start until transcription finishes or fails; always end it.

## Notifications (UNUserNotificationCenter; request authorization at first launch)
- Recording started: "Recording <Lecture> · <Session>"
- Recording failed / stopped unexpectedly
- Silence warning (above)
- Still recording after 3 h, then every hour: "Still recording — <h:mm>. Forgot to stop?"
- Low disk space
- Transcript saved (click → reveal in Finder)
- Transcription failed
Show notifications even when the app is frontmost (implement `willPresent`).

## UI
Main window, fixed size ~320 wide, content-sized, not resizable, title "Nosy". System font, native controls, looks clean in light and dark mode.
- **Lecture**: Picker listing existing subfolders of the transcripts root (sorted, case-insensitive) + "New lecture…" which reveals a TextField. Remember last used lecture (UserDefaults).
- **Session**: TextField pre-filled with today `yyyy-MM-dd` (re-fills on each new idle state if the user hasn't edited it).
- **One big button**: green "Start" ↔ red "Stop" (keyboard: Return starts, Space or Return stops — at least one shortcut each). Disabled while transcribing. Fields disabled while busy.
- **Status line**: recording → red dot + timer (m:ss, h:mm:ss over an hour) + a horizontal level bar; transcribing → spinner + "Transcribing…" + elapsed; done → "Saved · Show in Finder"; failed → error text + Retry; banners for recovery / missing model / silence warning.
- Closing the window during recording does NOT stop recording; app keeps running (don't terminate after last window closed). Clicking Dock icon reopens window.
- **Menu bar** (`MenuBarExtra`): while recording shows a red record glyph + timer; while transcribing a waveform glyph; idle a plain mic glyph. Menu: Show Window, Stop Recording (when recording), Quit.
- **Quit protection**: `applicationShouldTerminate` → if recording or transcribing, alert "A lecture is still recording/transcribing. Quit anyway?" (Quit / Cancel). If quit anyway during recording: stop cleanly, finalize wav, mark failed "Quit before transcription" so recovery offers it next launch.

## Build (`build.sh`)
- `swiftc -O -parse-as-library -target arm64-apple-macos26.0` all Sources → `$BUILD_DIR/Nosy.app/Contents/MacOS/Nosy` (default `~/Library/Caches/Nosy Build`); copy Info.plist + icons and fonts; sign with hardened runtime and `Resources/Entitlements.plist` (audio-input entitlement). Use `NOSY_CODESIGN_IDENTITY` when supplied; default and fallback: ad-hoc (`-`).
- `./build.sh install` also copies to `/Applications/Nosy.app` (replace existing; quit running instance first via `osascript -e 'quit app "Nosy"'` ignoring errors).
- Must build with zero errors; fix warnings where reasonable. Swift 6 strict concurrency: use `@MainActor` for UI state, do audio tap work on the audio thread without touching MainActor state directly.

## Tests (`tests/`)
- `tests/run_unit.sh`: compiles `Sources/Core.swift` + `tests/CoreTests.swift` (a plain `main` with assertions, no XCTest needed) and runs it. Cover: sanitizing, unique naming (-2, -3), WAV header correctness (parse it back; check with `afinfo`), markdown + paragraphing + marker stripping + empty transcript, duration math, retention selection, recovery scan selection.
- `tests/run_pipeline.sh`: uses `say -o` to synthesize ~20 s of English lecture-style speech with jargon (e.g. "glycolysis", "NADH", "phosphofructokinase"), converts to 16 kHz mono s16le raw PCM with `afconvert`, places it as an unfinished recording in a temp `NOSY_SUPPORT_DIR`, then exercises the real WAV-writing + whisper + markdown code path headlessly (add a hidden CLI mode to the app binary, e.g. `--headless-transcribe <id>`, which uses the same code as Retry). Assert the .md exists in a temp `NOSY_TRANSCRIPTS_DIR`, header fields are right, and at least some expected words appear. Also run once with a `vocab.txt` present.
- `tests/run_crash.sh`: launches the built app binary with temp dirs and a hidden `--headless-record <seconds> <lecture> <session>` mode that starts real recording; `kill -9` it mid-recording; then runs recovery via `--headless-recover` and asserts the pcm became a valid wav (afinfo), sidecar is `failed`, and transcription via retry produces a .md. (Needs mic permission; if denied, the script must print SKIPPED clearly rather than fail mysteriously.)
- Never write into the real `~/Desktop/Lecture Transcripts` or real support dir during tests.

## Done means
- `./build.sh` succeeds; `tests/run_unit.sh` and `tests/run_pipeline.sh` pass (crash test may report SKIPPED for permissions).
- Final message: what you built, files, test results (paste the summary lines), anything you could not do or deviated on.
