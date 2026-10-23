# Vocabulary validation — 2026-10-23

whisper.cpp 1.9.5 (Homebrew), large-v3-turbo, four threads, VAD enabled. The complete 52-minute owner-supplied lecture was copied before processing and boosted with `AudioFiles.boosted`. No audio was played.

The supplied 74-term prompt takes 306 native tokens, beyond the model's 224-token prompt context. Nosy keeps complete comma/newline-separated terms in their original order within 160 tokens. This prompt retained its first 40 terms (158 tokens), independently confirmed with native `whisper_tokenize` against the same model. The Swift tokenizer reads only model vocabulary data; it does not load the speech engine or weights.

## Cause and workaround

[`whisper.cpp` v1.9.5](https://github.com/ggml-org/whisper.cpp/blob/v1.9.5/src/whisper.cpp#L7092-L7140) tokenizes the initial prompt, but `-mc 0` disables its insertion along with decoded history. VAD uses the same transcription parameters.

With N prompt tokens, Nosy uses `--prompt TEXT --carry-initial-prompt -mc N+1`. The [decoder's context assembly](https://github.com/ggml-org/whisper.cpp/blob/v1.9.5/src/whisper.cpp#L7285-L7302) takes N static tokens and one previous-token marker, leaving exactly zero slots for earlier decoded text. Empty vocabulary or unreadable model vocabulary retains `-mc 0` and supplies no prompt.

Upstream still omits all text conditioning at fallback temperatures >= 0.5 and clears the static prompt for later windows starting within the final approximately five seconds. This CLI workaround therefore cannot promise a prompt on literally every decode attempt. Nosy preserves those safety fallbacks; no retrieval, redecoding, or upstream fork is included.

## Full-lecture comparison

Both runs used the same boosted WAV and CLI arguments, apart from vocabulary conditioning:

```sh
whisper-cli -m "$MODEL" -f "$BOOSTED_COPY" -l en -otxt -of "$OUTPUT" -np -pp -t 4 --vad -vm "$VAD_MODEL" -mc 0
# Prompted arm: replace -mc 0 with:
# -mc 159 --prompt "$BUDGETED_PROMPT" --carry-initial-prompt
```

| Metric | Plain | Prompt |
|---|---:|---:|
| Words | 4,544 | 4,739 |
| Maximum repeated sentence count | 1 | 1 |
| Sentences repeated >5 times | 0 | 0 |
| Distinct requested terms present | 10/15 | 9/15 |

| Term occurrences | Plain | Prompt |
|---|---:|---:|
| interferon | 3 | 3 |
| selectin | 0 | 0 |
| LFA-1 | 0 | 0 |
| ICAM | 1 | 2 |
| CXCL8 | 0 | 0 |
| diapedesis | 0 | 0 |
| thymocyte | 27 | 28 |
| DiGeorge | 0 | 0 |
| C4b2a | 2 | 1 |
| C3b | 1 | 0 |
| NK cell | 1 | 3 |
| macrophage | 5 | 5 |
| dendritic cell | 2 | 4 |
| CD4 | 7 | 8 |
| CD8 | 7 | 8 |

Counts are case-insensitive, word-bounded, and allow a trailing plural `s`. Repeated sentences are normalized to lowercase words after splitting on sentence punctuation, with at least three words; repeated transcript lines were also checked (maximum one in either arm). The outputs differ, confirming effective prompting. A second prompted full-lecture run through the final production `Transcriber` matched the candidate text exactly and had no loops.

This passes the prompt-applied/no-loop shipping gate on this lecture, but is not an accuracy improvement claim: target coverage declined from 10 to 9. These are term-presence counts, not audio-verified accuracy or WER. The earlier unbudgeted, history-enabled Python experiment's 542-line loop was not reproduced with prompt-only context.
