# Optional built in summaries builder checks

> Historical verification from the `r8-llm` development work recorded in integration commit `709438a` (2026-10-25); the exact tested worktree commit was not recorded. These results and UI descriptions apply to that development period, not necessarily the current app.

Built on branch `r8-llm`, based on `851def9`, in the dedicated worktree. No install, push, merge, audio playback, full unit suite, native click suite, or pipeline suite was run.

## Reproduce

```sh
./scripts/build-llama.sh
BUILD_DIR="$HOME/Library/Caches/Nosy Build r8llm" ./build.sh
swiftc -typecheck -swift-version 6 -strict-concurrency=complete -parse-as-library -target arm64-apple-macos14.0 -module-cache-path /tmp/nosy-mc-r8l -I Native -F vendor/sparkle Sources/*.swift
./tests/run_local_models.sh
"$HOME/Library/Caches/Nosy Build r8llm/Nosy.app/Contents/MacOS/Nosy" --headless-snapshot "$PWD/vendor/previews/local.png" --local-models
```

The whisper helper was copied read only from the owner's existing vendor build into this worktree's ignored `vendor/whisper`. `scripts/build-llama.sh` verifies its cached immutable source archive every time, builds only `nosy-llama`, and checks arm64 and system library dependencies. `build.sh` bundles and signs both helpers separately. No weights are bundled.

## Results

* Build and deep signature verification pass. Static Metal helper: 10,067,512 bytes before application signing; 10,009,136 bytes signed in the app, about 10.0 MB of added uncompressed app size. No Homebrew runtime, server, curl library, or audio library is linked into it.
* Swift 6 complete concurrency typecheck for macOS 14 passes. The existing synchronous AVAsset `tracks(withMediaType:)` deprecation warning is unchanged.
* Focused local model tests cover default Off/manual settings, provider grouping, 8 GB and 16 GB recommendations, pinned metadata, bounded chunking, timestamp checks, term ordering, HTTP progress/cancel/resume, an ignored Range header, file URLs, failed SHA256, changed receipts, removal, download shutdown, helper arguments, map cache reuse, hierarchical reduction, dense input context retries, paused timeout accounting, child cancellation, and synchronous recording suspension (verified via process state).
* Existing `SummaryTests.swift` passes when compiled and run alone with all app sources and `NOSY_UI_TEST`. The summary test compile command in `run_unit.sh` was updated for the new app activity guard dependency; the full script was not run.
* Focused snapshots include all six download/load/error states, the smaller model card, and the reader with Provider Off, in light and dark appearances. Images are under ignored `vendor/previews`. Inspect the images after running the command above.

## Real model test

The two model manifests were checked against Hugging Face's pinned tree API and LFS SHA256 metadata. SmolLM3's pinned resolve URL also returned HTTP 200 and the matching linked hash and byte count. GitHub's `b11869` ref resolved to `d327bf1f0780f87b8c01b367b61853b0c291d7c4`.

One Qwen3 4B Q4_K_M download completed and passed the pinned SHA256 and exact byte count. The real file and verification receipt are retained in `~/Library/Application Support/Nosy/models/llm/`. No SmolLM3 weights were downloaded.

The corrected real test processed a short synthetic enzyme transcript with timestamps, mapped it, generated all three sections separately, and saved a normal summary document through `SummaryFiles.save`. The measured run took **26.92 seconds** on this 16 GB Mac (`Mac16,1`). Output had concise notes, four alphabetical terms, and ten questions with brief answers. Manual comparison found the facts and timestamps supported by the fixture, without unsupported textbook elaboration. This is a small smoke test, not the research bake off. Earlier iterations exposed a prefill indexing error and conflicting format instructions; those were fixed before this result.

For an explicitly authorized rerun with the retained model:

```sh
./tests/run_local_models.sh --real "$PWD/vendor/llama/nosy-llama"
```

The real test's transcript, output, and timing are kept under ignored `vendor/real-*`. Public fixture excerpt notes may remain in the model cache; removing the model also removes its excerpt note cache.

## Limits and integration follow up

* SmolLM3 inference, long lecture quality, power measurements, and real 8 GB memory pressure still need the research bake off. Its URL and hash are verified, but its generation quality is unmeasured here.
* Saved transcripts do not retain every Whisper segment timestamp. This implementation splits at available paragraph/marker boundaries, preserves existing time tags, and labels missing or fabricated references as `time not stated`. Exact segment timing needs a future transcript/sidecar change outside this builder's permitted files. Dense text that exceeds the real context limit retries in smaller chunks.
* An active helper is stopped synchronously before recording or transcription starts and remains suspended during thermal/battery back off. Paused time does not consume the helper timeout. Each one shot process releases its model memory on exit; quit cancels and reaps it and any model transfers.
* The reader opens the normal Settings view directly on its Summaries pane in a retained settings window, without edits to App.swift or General/connector settings. Integration can unify this with its own settings navigation if desired.
