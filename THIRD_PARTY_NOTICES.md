# Third-party notices

Reviewed against the linked upstream repositories and model cards on 2026-10-23. The MIT license for Nosy's own code does not replace third-party licenses.

## Bundled fonts

- **Bricolage Grotesque** — Copyright 2022 The Bricolage Grotesque Project Authors. SIL Open Font License 1.1. [Upstream project](https://github.com/ateliertriay/bricolage), [upstream license](https://github.com/google/fonts/blob/main/ofl/bricolagegrotesque/OFL.txt), [included full license](Resources/Fonts/OFL-BricolageGrotesque.txt).
- **Hanken Grotesk** — Copyright 2021 The Hanken Grotesk Project Authors. SIL Open Font License 1.1. [Upstream project](https://github.com/marcologous/hanken-grotesk), [upstream license](https://github.com/google/fonts/blob/main/ofl/hankengrotesk/OFL.txt), [included full license](Resources/Fonts/OFL-HankenGrotesk.txt).

The font files and their complete license notices are included in `Resources/Fonts/` and copied into the app bundle by `build.sh`. Font redistribution remains subject to OFL 1.1.

## Bundled transcription engine

**whisper.cpp v1.9.5**, including its vendored GGML — MIT license, The ggml authors. Nosy bundles an arm64 `whisper-cli` in `Contents/Helpers/`, with static Whisper/GGML libraries and embedded Metal shaders. Built from the pinned source by `scripts/build-whisper.sh`; no Homebrew runtime is required. [Source](https://github.com/ggml-org/whisper.cpp/tree/v1.9.5), [license](https://github.com/ggml-org/whisper.cpp/blob/v1.9.5/LICENSE).

The complete upstream license follows and is also shipped in the app's `Contents/Resources/THIRD_PARTY_NOTICES.md`:

```text
MIT License

Copyright (c) 2023-2026 The ggml authors

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
```

The CLI also includes **miniaudio** by David Reid and **stb_vorbis** by Sean Barrett under their public-domain (Unlicense) options. [miniaudio license](https://github.com/ggml-org/whisper.cpp/blob/v1.9.5/examples/miniaudio.h), [stb_vorbis license](https://github.com/ggml-org/whisper.cpp/blob/v1.9.5/examples/stb_vorbis.c). Their shared Unlicense text follows:

```text
This is free and unencumbered software released into the public domain.

Anyone is free to copy, modify, publish, use, compile, sell, or distribute this
software, either in source code form or as a compiled binary, for any purpose,
commercial or non-commercial, and by any means.

In jurisdictions that recognize copyright laws, the author or authors of this
software dedicate any and all copyright interest in the software to the public
domain. We make this dedication for the benefit of the public at large and to
the detriment of our heirs and successors. We intend this dedication to be an
overt act of relinquishment in perpetuity of all present and future rights to
this software under copyright law.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN
ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.

For more information, please refer to <http://unlicense.org/>
```

## Models downloaded at runtime

- **Whisper large-v3-turbo** — Copyright (c) 2022 OpenAI. MIT license for code and model weights, confirmed by the [Whisper license](https://github.com/openai/whisper/blob/main/LICENSE), [upstream README](https://github.com/openai/whisper#license), and [large-v3-turbo model card](https://huggingface.co/openai/whisper-large-v3-turbo). Nosy downloads the [whisper.cpp GGML conversion](https://huggingface.co/ggerganov/whisper.cpp/blob/main/README.md), `ggml-large-v3-turbo.bin`, during setup. Weights are not included in this repository or app bundle.
- **Silero VAD v5.1.2** — Copyright (c) 2020-present Silero Team. MIT license. [Source and full license](https://github.com/snakers4/silero-vad/blob/master/LICENSE), [GGML conversion model card](https://huggingface.co/ggml-org/whisper-vad/blob/main/README.md). The optional `ggml-silero-v5.1.2.bin` voice activity model is downloaded during setup, not bundled.

Keep the relevant upstream copyright and license notices with any separate redistribution of engine binaries or weights.

## Original artwork

The Nosy app icon and mark are original artwork by Bardya, the app's owner, and are included under the repository's MIT license. Source artwork is in `Resources/Brand/`. Preview images show sample data.

## Vocabulary data

The development-only term lists and provenance CSV in `Resources/Vocabulary/` have separate source attribution and unresolved redistribution questions documented in [SOURCES.md](Resources/Vocabulary/SOURCES.md). They are not automatically licensed as a whole under Nosy's MIT license and are not bundled by the current build script. Review the flagged sources before public or commercial redistribution.
