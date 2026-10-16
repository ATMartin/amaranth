# ASR 0001: Production transcription pipeline (T06)

Date: 2026-10-16 · Task: T06 · Status: Accepted for v0 (`asr-pipeline-v8`). Quality gates are measured only on
public data until the user's real-call corpus arrives.

## Decision

**Preparation** (`ASR/Prepare`). A file-backed 16 kHz mono PCM16 derivative is built per source. Sample *i* sits at
session time *i*/16000, so a window can be read by offset without loading the meeting into memory.
- Each epoch gets its own `AVAudioConverter`, so sample-rate changes are resampled per epoch.
- The downmix is anti-phase safe: L = −R does not cancel.
- A coverage map labels every interval `transcribed` (recorded), `paused`, `missingAudio`, and so on.
  Gaps read back as zeros but are never labelled silence.
- Derivatives are reproducible from the immutable segments and can be deleted.

**Windows** (`ASR/Pipeline/TranscriptionPipeline.swift`). Windows **partition all recorded audio**. VAD (Silero) only
chooses cut points at the middle of silences, so speech that VAD misses is still transcribed.
- Each window is decoded with **2 s of acoustic context on each side**. Only words whose midpoint falls inside the
  window's own span are kept, so there are no duplicates by construction.
- Every engine call is ≤ 14.9 s: one single pass inside Parakeet's 15 s window.
- `ParakeetASR.transcribe` **refuses longer input** (`InputError.tooLong`).

**Under-yield guard.** If at least 2 s of VAD speech in a window's span has no word within 0.6 s, the window is
re-decoded. The retries use other contexts within the same single-pass budget: 0.3/0.3, 0/0, forced 2/2, maximum
left, and maximum right. The pipeline keeps the best-covered result that is not garbled.
- An empty or garbled re-decode is never accepted as a fix.
- Text is never invented.
- **Residual losses are surfaced.** Any VAD speech still without a word nearby after the retries, in stretches of
  1 s or more, becomes a coverage region with status `failed` ("speech detected, no text"), not `transcribed`.
  Notes and UI must treat it as unknown (`untranscribedSpeechIsReportedAsFailedCoverage`).
  Measured: 11 s on ES2004a, 16 s on IS1009a, 72 s on EN2002a and 16 s on far-field (production-eval). Some of this
  is crosstalk or laughter that VAD calls speech.
- **Blind spot:** the guard can only see losses where VAD detected speech. Speech that VAD misses is still decoded
  (windows partition all audio), but a skip there is not detected.
- **Retry acceptance:** when the first decode is garbled, the first non-empty, non-garbled re-decode replaces it,
  even if it covers less. Any loss that results is then reported as `failed` coverage, so it is not hidden.

The garble/loop detector shares the same bounded retry (FluidAudio#760).

**Checkpoints.** Each window's result is written atomically, keyed by pipeline version, window policy, source and
index. A cancelled or crashed job resumes without re-running completed windows. Progress is reported per window
through the worker contract.

**Long path fenced off.** FluidAudio's long path survives only as `ParakeetASR.benchmarkOnlyTranscribeLong`, for the
harness's reference row. `productionCodeNeverUsesTheChunkDroppingLongPath` fails if ASR/Pipeline, ASR/Prepare,
InferenceWorker, App, Diarization or Domain call it, or call the decoder-state API.

## Two engine defects found (FluidAudio 0.17.7, Parakeet TDT v3)

1. **FluidAudio's internal chunking drops whole chunks for inputs over 15 s.** The loss depends on content and is
   not monotonic in length. Measured: 23.5 s → 47 words, 24.0 s → 37, 24.5 s → 50. Tail padding does not fix it. This
   long path gave the best AMI numbers in our sweeps ("REF fluid-long-300s" below), but it silently loses speech, so
   it is **never used**. The guard in `ParakeetASR` enforces this.
   *Effect on earlier numbers:* the T02 batch WERs in models/0001 used this path. Some of their deletions came from
   dropped chunks, not from the model.
2. **Greedy TDT sometimes skips a whole stretch of clear speech inside a single pass.** This is deterministic and
   depends on content. Example: LibriSpeech window 63.7–74.8 s. With 0.3 s context it gives 27 correct words. With
   1.5 s context on both sides it gives *only the 3 words of the right context*; the whole 11 s span is skipped. With
   2.0/1.0 s context it is correct again. Found because wider context made LibriSpeech WER jump from 0.8% to 15%.
   The under-yield guard above is the fix.

## Measurements

Window policy sweep (`amaranth-bench asr-sweep`), with the under-yield guard. Values are WER, with non-overlap WER in
parentheses. Raw output: [`evidence/2026-10-16/asr-sweep.txt`](../../qualification/evidence/2026-10-16/asr-sweep.txt).

| Policy | ES2004a headset | IS1009a headset | EN2002a headset | ES2004a far-field | LibriSpeech 1089 |
|---|---|---|---|---|---|
| 0.3 s at silences, 2/1 s forced | 17.3 (11.6) | 23.1 (15.2) | 32.7 (16.8) | **23.1** (21.1) | **0.8** |
| 1.0 s at silences, 2/1 s forced | 16.1 (9.5) | 22.5 (17.1) | 32.5 (16.4) | 24.2 (22.2) | 1.4 |
| **2 s everywhere (chosen)** | **16.1 (9.5)** | **20.8 (15.2)** | **31.4 (16.2)** | 24.0 (20.9) | 1.0 |
| Reference only: FluidAudio long path, 300 s blocks (drops chunks) | 15.8 (10.1) | 21.1 (15.0) | 29.9 (14.5) | 24.6 (20.9) | 1.8 |

The same sweep **without** the guard was much worse. Examples: the 0.3/2/1 policy scored 18.5 / 28.6 / 36.0 / 23.9;
the 2 s policy scored 19.9 / 25.8 / 34.4 / 26.0 with LibriSpeech at 9.7%.

Production evaluation (`amaranth-bench production-eval`), current code:
[`production-eval-asr-v8.txt`](../../qualification/evidence/2026-10-16/production-eval-asr-v8.txt).
Words are identical in v7 and v8; v8 only adds `failed` coverage.
It was re-run with networking denied, with identical results:
[`production-eval-offline-sandbox.txt`](../../qualification/evidence/2026-10-16/production-eval-offline-sandbox.txt).

| Version | AMI clean (3 headset meetings), all words | AMI clean, non-overlap | Far-field, non-overlap | LibriSpeech e2e |
|---|---|---|---|---|
| v1: VAD windows | 30.6 | 15.3 | 26.8 | 0.5 |
| v6: gap-adaptive context, no guard | 31.5 | 14.7 | 22.7 | 14.9 |
| **v7/v8: 2 s context + under-yield guard** | **26.5** | **13.9** | **20.9** | **0.5** (test), 1.0 (sweep) |
| T02 batch reference (FluidAudio long path) | 27.3 | 13.8 | 20.4 | – |

ASR runtime on the M2 Max is 10–29 s per 14–36 min AMI meeting (RTF ≈ 0.01). Silence, noise and music controls give 0
words.

**How far to trust these numbers:**
- **In-sample tuning.** The window policy and the guard thresholds (2.0 s uncovered, 0.6 s proximity, 1.0 s
  reporting) were chosen on the same four AMI recordings and one LibriSpeech speaker used to report them. Expect some
  optimism. They must be re-checked on the held-out real-call set.
- **The chosen policy is not best everywhere.** "2 s everywhere" wins the three headset meetings but loses far-field
  (24.0 vs 23.1) and LibriSpeech (1.0 vs 0.8) to "0.3 s at silences". It was chosen because the headset/call case is
  the product's main case.
- **Non-overlap WER is a thin sample.** It counts only reference segments of at least 1 s with no other speaker:
  1,312 words across the three clean meetings. Those are easier than average.
- **All-words WER fails the bar.** At 26.5% on clean AMI it is far above plan §10's 15%. Attributing the gap to
  overlapped speech is plausible from the non-overlap numbers but is not separately demonstrated.
- **Version rows.** The v1–v6 rows come from this session's earlier runs. Only v7/v8 are reproducible from the
  shipped evidence and code. Older pipeline versions are not kept.

## Acceptance (T06)

| Criterion | Evidence | Status |
|---|---|---|
| Boundary fixtures keep opening/closing words, dates, numbers and negations, with no duplicates | `boundariesPreserveNumbersDatesAndNegationsWithoutDuplicates`: synthetic speech generated at test time with macOS `say` (one voice, Samantha), decoded with 8 s windows (6 boundaries) and with the default (3 windows, about 2 boundaries). It checks 8 date/number facts in either written form, negation counts (not/never/no/nobody), no adjacent duplicate words, and first and last words. The LibriSpeech e2e checks first and last words. | Met |
| Pause/resume, sample-rate changes and gaps keep global timestamps; unknown coverage never omitted | `pauseAndSampleRateChangeKeepGlobalTimestamps` (48 kHz stereo → pause → resume → 44.1 kHz mono rebuild); `derivativeIsTimelineAlignedAndGapsAreNotSilence` (a stall is `missingAudio`); `untranscribedSpeechIsReportedAsFailedCoverage` (engine under-yield is `failed`, not `transcribed`) | Met |
| Held-out WER and runtime per subset; silence/music give no invented sentences | Table above; `silenceAndToneProduceNoWords`; production-eval controls | **Measured on public data only.** Plan §10 sets ≤ 15% clean / ≤ 25% noisy on a held-out corpus of *real calls*. AMI is not that corpus, and no real-call set exists yet (tracked item 9). On AMI, clean non-overlap WER is 13.9% and all-words WER is 26.5%. Overlapped speech dominates the difference. |
| Cancel/restart yields the same transcript without re-running valid chunks | `transcribesRecordedSpeechAccuratelyAndResumesFromCheckpoints`: cancel after 3 windows and resume. The test asserts that checkpoint files written before the cancel are untouched (modification times unchanged, so they were not re-decoded). It asserts that the resumed transcript, words and coverage, equals an uninterrupted run from scratch in a fresh directory, and that a re-run with all checkpoints is identical. | Met |
| Surface silence, hallucination and unsupported-language states | `noSpeech`/`missingAudio`/`paused` coverage; `questionableText` flags from the garble detector | Partial. The `unsupportedLanguage` status exists in the contract, but nothing sets it yet: there is no language ID. v0 is English (decision 0003). Parakeet v3 covers 25 European languages. Tracked. |
