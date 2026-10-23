# Vocabulary maximum → lean — 2026-10-23

The full local report and reproducible evidence are in `~/nosy-work/vmax/ABLATION.md`. No audio was played. Both originals match their copied inputs by SHA-256. The installed app and original transcript folder were not changed.

The maximum prototype is commit `534420f2c79dbf46ce3f384c710856add1367260` on `vocab-max`. It implemented independently switchable routing, spelling/phonetic retrieval, one persistent libwhisper worker for selective prompt retries, gated trie callback retries, restricted edit acceptance and conservative substitution. The final commit removes the stages that did not pay for their cost.

The app ships ten course subjects and 49 plain word-list packs, saved folder-level subject choices and bounded course-name guessing, the audited transcript router, cached phonetic/spelling retrieval, conservative uncertain-spelling substitutions, and **Fix this word…** in the transcript selection menu. Subject refinement now follows each course's vocabulary choice: **Auto** by default, an explicit subject, or **None** to disable it. The former global toggle is removed. Custom user terms still use the existing native-counted 160-token first-pass prompt, with no decoded history. No source metadata, CSV, native helper or additional runtime model is bundled.

## Product-baseline results

Apple M4, 16 GiB, whisper.cpp 1.9.5 / large-v3-turbo, Metal, four threads. The baseline uses the existing boosted-copy/VAD/CLI pipeline with no vocabulary prompt. All accepted output preserves unrelated baseline text exactly. The table counts text-supported repairs; there is no audio-verified reference or WER claim.

| Arm | MBB 326 fixes / new errors | MBB 326 added seconds | MBB 322 fixes / new errors | MBB 322 added seconds |
| --- | ---: | ---: | ---: | ---: |
| Baseline | 0 / 0 | 0 | 0 / 0 | 0 |
| Router + broad retrieval | 0 / 0 | 10.32 | 0 / 0 | 18.45 |
| Router + prompt retry | 0 / 0 | 52.85 | 1 / 0 | 28.16 |
| Router + trie retry | 0 / 0 | 49.82 | 1 / 0 | 27.86 |
| Router + broad retrieval + substitution | 0 / 0 | 10.32 | 1 / 0 | 18.45 |
| **Lean cached phonetic substitution** | **0 / 0** | **2.64** | **1 / 0** | **2.73** |

Baseline time: **104.11 / 105.75 s**. Lean composed total: **106.75 / 108.48 s**. Baseline component peak RSS: **2.120 / 2.095 GiB**; lean postprocessing alone: **34.3 / 32.3 MiB**. The timer process includes cold and warm text passes; the table uses the separately measured single cold pass. The local report includes full-umbrella, routed, prompt/trie, substitution and combined arms, raw `/usr/bin/time -l` logs, acceptance replay accounting and peak memory.

**None of the supplied target errors was fixed against the product baseline.** The extra MBB 322 repair is `heterochromatone` → `heterochromatin`. Most MBB 322 target phrases are absent as standalone entries in the supplied Biology catalog; acronyms and badly garbled phrases deliberately abstain. These lectures and the confidence threshold are development data.

A separate control gave baseline and prompted retry identical independent 30 s windows/decoder settings. Prompting accepted zero repairs on either lecture. Substitution fixed the predeclared `diapodesis` → `diapedesis` once on that control's MBB 326 output. The alternative baseline was not adopted as a product improvement.

Every evaluated output was reconstructed from its baseline plus exact UTF-16 edit ranges and checked byte-for-byte. The two unique changed spans were reviewed in text, and no introduced error was identified. The MBB 322 baseline has one repetition-detector flag (`wear your sunscreen` three times); it remains unchanged. **No new loop was introduced.** Zero observed introduced errors on these two text reviews does not establish broad acoustic accuracy, so the automatic feature stays off by default.

## Final production-path measurement

Fresh end-to-end runs of the final `Transcriber` (normalized input copies, normal CLI/VAD, volume scan, JSON, refinement, ledger and Markdown output) reproduced both saved baselines **byte-for-byte** and the lean edit lists exactly. Retained input WAVs matched their source copies; both records finished, and temporary files were removed. Audio compression/retention were disabled in the isolated fixture. These are separately measured full-process numbers, rather than the composed stage totals above.

| Lecture | Known targets fixed | Additional fixes | New errors (text review) | Actual wall s | Actual peak RSS GiB |
| --- | ---: | ---: | ---: | ---: | ---: |
| MBB 326 | 0 | 0 | 0 | 110.55 | 2.295 |
| MBB 322 | 0 | 1 | 0 | 110.72 | 2.275 |

The empty-custom-vocabulary path now returns before parsing the model tokenizer; a final measurement caught that unnecessary work and the complete checks/runs were repeated after fixing it. Previous pre-fix runs are retained separately and excluded from this final table. Baseline-only CLI numbers and these integrated-process peaks have different process scopes; do not infer the ~35 MiB text stage itself uses gigabytes.

## Cut and retained rules

Selective audio redecoding and trie logit biasing added 28–92 seconds without an extra accepted repair over substitution. Their native helper, callback, audio clipping and word alignment code were deleted. Callback calls/bonuses are recorded in the local results, so API feasibility was tested. A matched-window control confirmed the cut.

The final index first requires an exact phonetic bucket before small spelling reranking; it caches immutable indexes and bounded query results. A replacement needs spelling similarity ≥0.85, margin ≥0.15, original geometric-mean token confidence <0.65, identical word count and exact source-range validation. Short/acronym/letter-digit cases, missing confidence, ambiguity and repetition flags abstain. The phonetic fold is original consonant-based retrieval, not Double Metaphone or an acoustic phoneme model. All work remains local at utility priority.

Validation: `./build.sh`, `tests/run_unit.sh`, `tests/run_pipeline.sh` including the opt-in JSON/ledger path, and strict Swift 6 macOS 14 typecheck. The cache app contains all vocabulary resources and no retry helper. Unit tests cover routing, retrieval, accept/reject gates, abstention, source confidence, settings, prompt priority and correction persistence.
