# Upstream bugs (local; not reported)

Draft reports for review before anything is posted to a public tracker. Both affect **FluidAudio 0.17.7** with the
Parakeet TDT 0.6B v3 Core ML models (`FluidInference/parakeet-tdt-0.6b-v3-coreml` @ 7dd20fe6) on macOS 26.5.2, M2 Max.
Amaranth works around both (see `docs/decisions/asr/0001-asr-pipeline.md` and `docs/decisions/live/0001-live-text.md`).

---

## 1. `AsrManager.transcribe(_:decoderState:)` silently drops whole chunks for inputs longer than 15 s

**Severity:** high. Speech is lost with no error and no flag.

**What happens.** For sample arrays longer than `ASRConstants.maxModelSamples` (about 15 s), `transcribeWithState`
routes to `ChunkProcessor`, which uses 14.96 s chunks with 2 s overlap and silence-aligned starts. Depending on the
input, whole internal chunks contribute no tokens. The loss is not monotonic in input length:

| Input (same audio, truncated) | Words returned |
|---|---|
| 23.5 s | 47 |
| 24.0 s | 37 |
| 24.5 s | 50 |

Appending trailing silence ("tail padding") does not prevent it.

**Repro.**
1. Take a LibriSpeech test-clean concatenation (1089-134686 utterances joined with 0.6 s pauses).
2. Call `transcribe(samples, decoderState: &state)` with prefixes of 23.5, 24.0 and 24.5 s.
3. Compare word counts against the reference.

The harness command `amaranth-bench asr-probe` and the `benchmarkOnlyTranscribeLong` path in
`ASR/Engines/ParakeetASR.swift` reproduce it.

**Expected.** Every input second is decoded (or an error is thrown). Word counts should grow with input length.

**Impact on us.** Our T02 batch WER numbers used this path, and some of those deletions were dropped chunks.

**Workaround.** Never pass more than 14.9 s. `ParakeetASR.transcribe` throws `tooLong`, and our pipeline windows the
audio itself.

---

## 2. Greedy TDT decode can skip a whole stretch of clear speech within one single-pass window

**Severity:** high. The loss is content-dependent and deterministic.

**What happens.** In a single pass (≤ 15 s, no chunking), the greedy TDT loop in `TdtDecoderV3` sometimes emits only
a few tokens and then blanks through many seconds of clear speech. Whether it happens depends on the left and right
context included around the same speech.

**Repro.** `amaranth-bench asr-probe ModelStore <libri-1089 16 kHz wav> 63.74 74.75` decodes the same 11 s span with
different context (seconds before / after):

| Context | Words | Output |
|---|---|---|
| 0.3 / 0.3 | 27 | correct |
| 1.0 / 1.0 | 4 | "Well now, the first" |
| 1.5 / 1.5 | 3 | "Well now, Ennis." — the right context only; the whole 11 s span is skipped |
| 2.0 / 1.0 | 32 | correct |

The results are identical across repeated runs, and an independent validator reproduced them.

**Suspected area.** The inner blank loop reuses the decoder projection from before the blank run ("blanks don't change
the LM context"). Once the joint predicts blank with large durations from that state, it may never re-enter emission
for the span. We have not confirmed this, and have not checked whether NeMo's reference greedy decoder behaves the
same.

**Expected.** Comparable output regardless of a second or two of extra context.

**Workaround.** VAD- or energy-based detection of speech left without words. A window with ≥ 2 s of uncovered speech
is re-decoded with other contexts (and, live, split in halves); the best-covered result is kept. Residual loss is
reported as `failed` coverage. Without this guard, wider-context windows raised LibriSpeech WER from 0.8% to 15%, and
a live catch-up pass lost two whole stretches (20.8% WER).
