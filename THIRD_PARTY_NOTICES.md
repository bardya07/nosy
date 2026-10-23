# Third-party notices

Reviewed against the linked upstream repositories and model cards on 2026-10-22. The MIT license for Nosy's own code does not replace third-party licenses.

## Bundled fonts

- **Bricolage Grotesque** — Copyright 2022 The Bricolage Grotesque Project Authors. SIL Open Font License 1.1. [Upstream project](https://github.com/ateliertriay/bricolage), [upstream license](https://github.com/google/fonts/blob/main/ofl/bricolagegrotesque/OFL.txt), [included full license](Resources/Fonts/OFL-BricolageGrotesque.txt).
- **Hanken Grotesk** — Copyright 2021 The Hanken Grotesk Project Authors. SIL Open Font License 1.1. [Upstream project](https://github.com/marcologous/hanken-grotesk), [upstream license](https://github.com/google/fonts/blob/main/ofl/hankengrotesk/OFL.txt), [included full license](Resources/Fonts/OFL-HankenGrotesk.txt).

The font files and their complete license notices are included in `Resources/Fonts/` and copied into the app bundle by `build.sh`. Font redistribution remains subject to OFL 1.1.

## User-installed transcription engine

**whisper.cpp** — MIT license, The ggml authors. Installed separately by the user through Homebrew (`brew install whisper-cpp`); the executable and its dependencies are not bundled with Nosy or this repository. [Source](https://github.com/ggml-org/whisper.cpp), [license](https://github.com/ggml-org/whisper.cpp/blob/master/LICENSE).

## Models downloaded at runtime

- **Whisper large-v3-turbo** — Copyright (c) 2022 OpenAI. MIT license for code and model weights, confirmed by the [Whisper license](https://github.com/openai/whisper/blob/main/LICENSE), [upstream README](https://github.com/openai/whisper#license), and [large-v3-turbo model card](https://huggingface.co/openai/whisper-large-v3-turbo). Nosy downloads the [whisper.cpp GGML conversion](https://huggingface.co/ggerganov/whisper.cpp/blob/main/README.md), `ggml-large-v3-turbo.bin`, during setup. Weights are not included in this repository or app bundle.
- **Silero VAD v5.1.2** — Copyright (c) 2020-present Silero Team. MIT license. [Source and full license](https://github.com/snakers4/silero-vad/blob/master/LICENSE), [GGML conversion model card](https://huggingface.co/ggml-org/whisper-vad/blob/main/README.md). The optional `ggml-silero-v5.1.2.bin` voice activity model is downloaded during setup, not bundled.

Keep the relevant upstream copyright and license notices with any separate redistribution of engine binaries or weights.

## Original artwork

The Nosy app icon and mark are original artwork by Bardya, the app's owner, and are included under the repository's MIT license. Source artwork is in `Resources/Brand/`. Preview images show sample data.

## Vocabulary data

`Resources/Vocabulary` contains plain UTF-8 word lists and the umbrella-to-pack manifest, as selected for distribution by the repository owner. The app bundles these lists without source metadata or provenance CSV files. No external retrieval, phonetic, or contextual-biasing implementation was copied into the app.
