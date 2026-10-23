# UI audit resolution — 2026-10-23

Merged `codex-audit.md` (C1–C21) and `haiku-audit.md` (H1–H12), checked against current source and owner shots. Owner/lead decisions take precedence over the original design-E handoff. No recording or playback used for verification.

| Sources | Verified finding / disposition |
| --- | --- |
| C1 | BUG: external Open/notification and folder reload could drop a draft. All navigation now guards dirty edits with Save/Discard/Cancel and retains the original save destination. Activation reload preserves the editor. |
| C2, H1 | BUG: native titlebar safe area was counted outside the custom surface. Main surface subtracts that already-drawn safe area exactly once from its fitting height; transparent window has no extra native shadow. Native titled-window previews assert matching fitting/content bounds. H1's shadow-only fix was insufficient. |
| C3 | BUG: uncapped banners could move recording controls beyond the screen. Controls are pinned outside a height-capped scrolling body; setup/recovery notices wait until recording ends, and immediate microphone warnings take priority over older error/sleep notices. |
| C4, H4 | BUG: no speech was celebrated as saved. Shared word parsing handles the no-speech sentinel and marker-only/empty bodies. Heading, icon, status and notification now use a neutral no-speech outcome; file actions and Record another remain. |
| C5, H2 | BUG: custom overlay tooltips covered labels/status. Replaced them with native help; short single-line icon tips, no redundant Saved button tips. Folder: “Change folder.” |
| C6 | BUG: Saved cached old text/path after library edits, rename or Trash. Library mutation callbacks refresh the summary/current path; missing files disable actions; activation reloads external edits and Copy reads fresh text. |
| C7 | BUG: disabled Add Marker displaced Minimize. The marker command claims Command-M only while recording. |
| C8 | BUG: folder Change looked available during transcription. Settings and onboarding now use the same working lock as the action. |
| C9 | BUG: disabled inline actions retained active hover/press styling. Link style respects isEnabled. |
| C10 | BUG: failed microphone switch persisted the failed choice. Preference/checkmark commit only after the recorder succeeds; rollback retains the previous choice. |
| C11 | BUG: onboarding microphone authorization stayed stale. Refresh on appearance and app activation. |
| C12 | BUG: identical Record another labels performed different actions. Saved keeps Record another → Ready; immediate recording actions say Start recording. |
| C13 | BUG: light amber/faint small text had weak contrast. Darkened both light tokens. |
| C14, H11 | BUG/NOISE: a redundant transcription instruction truncated at normal sizes. Removed it and the duplicate identity; queue/power pause is wrapping status text, with a progress bar only for active transcription. |
| C15, H6 | BUG: Ready ignored configured subject. Row now shows the resolved primary subject or None and opens vocabulary. Editor states whether subject vocabulary is enabled. H6's assumption that packs always run was false: Smarter vocabulary is opt-in, so pack sizes are not added to custom counts. |
| C16, H3 | NOISE: zero stats. Duration/words/path remain; markers only above zero, vocabulary hits only when captured lecture vocabulary and hits are both nonzero. Terms are frozen in optional sidecar metadata; legacy unknown vocabulary is not guessed from today's file. |
| C17, H5 | NOISE: selectable two-line path. One line, middle truncation, no text selection. Reveal/Copy remain. Red selection was the native accent, not a custom error state. |
| C18, H7 | NOISE: idle mic routing/debug text and fake dB. Device name only; real levels remain in the recording waveform and its accessible value. Preview fixtures now use the real name path. |
| C19 | NOISE: CoreAudio default aggregate proxy in microphone menu. Filter only its known private prefix; preserve user-created aggregate devices. |
| C20, H10 | NOISE: recording diagnostics row / repeated paused sentence. Removed row; waveform, paused status and actionable audio warnings remain. |
| C21 | BUG: unnamed vocabulary editor and duplicated course menu accessibility. Editor has a course-specific label; menu is one element with decorative chevron hidden. |
| H8 | Rejected removal of folder utility: lead explicitly retained it with “Change folder” help. Three small utilities fit in 360 pt; shortened tips remove the verified collision. |
| H9 | No shortcut conflict or hidden-recording-hint bug: Return/Command-R start, Command-Return stops, Command-P pauses. Kept established functionality and one visible Command-R hint. Text fields consume Return through onSubmit; redundant start tooltip removed. |
| H12 | Vocabulary inconsistency verified; failed status now says Failed; active/queued/power-paused wording matches the library. No progress is fabricated for queued work. |

Validation includes dirty-draft and Saved-state regression tests in `tests/UITests.swift`, standard unit/pipeline suites, macOS 14 strict-concurrency typecheck, and light/dark previews of every main phase plus queue, power pause, no speech, minimal stats, missing transcript, warnings, long markers, new/subjectless courses, all five onboarding pages, vocabulary, Settings and minimum-size Transcripts. Native titled-window snapshots cover Ready, Recording and Saved.

Final checks passed: `./build.sh`, `tests/run_unit.sh` (153 core, 69 backend, 47 transcriber, 36 vocabulary assertions, plus UI regression scenarios), `tests/run_pipeline.sh`, and Swift 6 strict-concurrency typecheck targeting `arm64-apple-macos14.0`. Light/dark PNGs and native geometry output are in `~/nosy-work/uxdebug/fixed-previews/`; all unique states were visually inspected, including the constrained recording viewport. The native surface/content/fitting heights match in Ready, Recording and Saved in both themes. Existing synchronous AVAsset and worker-capture compiler warnings are outside this UI change.
