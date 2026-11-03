# Bundled whisper.cpp validation

Validated on 2026-10-23, Apple M4, using only this worktree's `build/` output. No audio was played and no app was installed in `/Applications`.

## Build and bundle

- whisper.cpp tag: `v1.9.5`; source archive SHA-256: `ff1a9053feb509ff9d7729703355541ae9690073a6b1c40eb692c962e0dc1720` (also matches the installed Homebrew formula).
- `./scripts/build-whisper.sh` passed. Only executable built: `whisper-cli`. Static Whisper/GGML, Apple Accelerate, embedded Metal shader sources, no OpenMP or SDL.
- `lipo -archs` reports `arm64`; Mach-O `LC_BUILD_VERSION` reports `minos 14.0`.
- Helper: `Nosy.app/Contents/Helpers/whisper-cli`; **7,778,576 bytes** after Developer ID signing (about 7.8 MB). The unsigned/stripped vendor output is 7,805,672 bytes; re-signing replaces the linker's signature allocation.
- `otool -L` lists only Accelerate, Foundation, Metal, MetalKit, CoreFoundation, `/usr/lib/libSystem.B.dylib`, `/usr/lib/libc++.1.dylib`, and `/usr/lib/libobjc.A.dylib`. No Homebrew, `@rpath`, or other third-party dylibs.
- Both ad-hoc and Developer ID builds passed. The app and helper have the same Developer ID identity/team, hardened runtime, and secure timestamps. `codesign --verify --deep --strict` passed. Notarization was not submitted.
- The complete whisper.cpp MIT license and decoder notices are copied into the app's resources in `THIRD_PARTY_NOTICES.md`.

## Functional checks

All generated files used worktree-local paths, with `BUILD_DIR="$PWD/build"` and `TMPDIR="$PWD/build/tmp/"`.

- `tests/run_unit.sh`: 144 core + 69 backend + 37 transcriber assertions passed (250 total). Includes bundled-engine precedence, missing/non-executable helper behavior, rehearsal, and development fallback.
- `tests/run_pipeline.sh`: passed using the **helper from the built app**. Real recognition with and without vocabulary, AAC compression, 44.1 kHz stereo M4A import/resampling, Retry from M4A, missing-engine audio preservation, and unique Markdown output. Metal active; no CPU fallback.
- `swiftc -typecheck -swift-version 6 -strict-concurrency=complete -parse-as-library -target arm64-apple-macos14.0 -module-cache-path build/module-cache -I Native -F vendor/sparkle Sources/*.swift`: passed. Existing Swift capture/deprecation warnings remain.
- Built app `--headless-snapshot`: passed; generated all six light/dark app, library, and settings images.
- Helper transcribed the pinned source's 11-second `samples/jfk.wav` with `env -i PATH=/usr/bin:/bin`, an absolute model path, and no shader resource environment. Logs report `using embedded metal library` and `using MTL0 backend`; recognized the expected speech.
- The packaged app also passed `--headless-import` in the same clean environment, with `NOSY_WHISPER_CLI=/nonexistent/whisper-cli`, isolated support/transcript directories, and a symlink to the existing downloaded model. This confirms packaged apps use the helper, ignoring development overrides.

Example clean-environment helper command after building:

```sh
env -i PATH=/usr/bin:/bin \
  "$PWD/build/Nosy.app/Contents/Helpers/whisper-cli" \
  -m "$HOME/Library/Application Support/Nosy/models/ggml-large-v3-turbo.bin" \
  -f "$PWD/vendor/cache/whisper.cpp-1.9.5/samples/jfk.wav" -l en -t 4 -mc 0
```

## Speed comparison

Same **96.749-second**, 16 kHz, mono, 16-bit WAV generated to a file with `say -v Samantha -r 155` and `afconvert`; no playback. Same downloaded large-v3-turbo model and arguments (`-l en -t 4 -mc 0 -otxt`), no VAD, on the same Apple M4. One warmup per engine, then three sequential measured runs per engine with alternating order. The bundled runs used only `PATH=/usr/bin:/bin` in an otherwise empty environment. Both engines reported `using MTL0 backend`; all runs produced identical transcript text.

| Engine | Run 1 wall time | Run 2 wall time | Run 3 wall time | Median wall time | Median Whisper time |
| --- | ---: | ---: | ---: | ---: | ---: |
| Bundled v1.9.5 | 5.839 s | 6.606 s | 6.458 s | **6.458 s** | 6.382 s |
| Homebrew v1.9.5 | 6.176 s | 6.520 s | 6.569 s | **6.520 s** | 6.396 s |

Bundled wall time is 0.96% lower, within run-to-run variation; about 15 times real time. The Homebrew v1.9.5 formula uses system GGML 0.27.0; the pinned source vendors GGML 0.26.0. No external GGML is needed by Nosy.
