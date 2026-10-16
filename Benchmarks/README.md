# Benchmarks (T02 replay harness, T03 capture qualification)

## Model replay harness: `amaranth-bench`

A release-mode harness for ASR, diarization and notes feasibility. Every measured run is a **separate child process**,
so peak footprint and cold load are per (engine, item). The parent prepares inputs and does all scoring, so scorer
memory never inflates a measurement.

```sh
swift build -c release --product amaranth-bench
.build/release/amaranth-bench corpus ModelStore Benchmarks/Fixtures/public Benchmarks/Results/<run> \
    --engines parakeet-v2,parakeet-v3,parakeet-v3-int8v2,whisper-turbo --timing --notes
# Re-score cached raw results without running anything:
.build/release/amaranth-bench corpus … --score-only
# Verify an installed model pack offline (networking denied by the sandbox profile):
sandbox-exec -p '(version 1)(allow default)(deny network*)' \
    .build/release/amaranth-bench verify-pack ~/Library/Application\ Support/Amaranth/Models <sample.flac> "<reference text>"
```

Models are loaded only from `ModelStore/` (or an installed pack) with all downloads disabled:
- FluidAudio `ModelHub.offlineMode`;
- the diarizer built by hand from `.mlmodelc` files;
- WhisperKit `download: false` plus an explicit tokenizer folder.

Pins: `docs/decisions/models/candidates.md`.

### Corpus (`Benchmarks/Fixtures/public`, sources and licenses in `SOURCES.md`)

| Subset | Items | Purpose |
|---|---|---|
| clean | AMI ES2004a, IS1009a, EN2002a headset mix (4 speakers, held-out test split) | Meeting WER; non-overlap WER; word-timing error; DER |
| difficult | AMI ES2004a single far-field array mic | Room/speakerphone proxy |
| read | LibriSpeech test-clean, 53 utterances (2 speakers) | Opening/closing word preservation; tail loss |
| control | 60 s digital silence, pink noise, synthetic chords | Hallucination (expect 0 words) |
| timing | 60 and 120 min concatenations of the AMI audio | Throughput and memory only (not quality) |

Public data **supplements** the plan's corpus. It cannot replace consented captured calls, which the user will
supply later for the held-out gates.

### Scoring

- **WER** uses normalization `amaranth-norm-v2`:
  - lowercase; unify apostrophes; drop bracketed annotations; hyphens become spaces; strip punctuation;
  - remove fillers (um/uh/mm/hmm…);
  - verbalize integer digits and ordinals ("15" → "fifteen", "3rd" → "third").

  It is computed by Levenshtein alignment, with S/D/I reported separately. Number-token errors are reported separately.
- **Non-overlap WER** scores only RTTM speaker segments that overlap no other speaker (≥ 1 s each). Hypothesis words
  are taken by time with a ±150 ms margin. This separates recognition quality from single-stream overlap loss.
- **Word timing:** median absolute start-time error of exactly matching words against AMI reference timings.
- **DER** (plan §10): no collar, overlap scored, optimal one-to-one speaker mapping (Hungarian), unknown labels count as
  missed attribution. Missed, false-alarm and confusion time are reported separately. Restricted to the AMI UEM.
- **Memory:**
  - `peak` is the process lifetime peak physical footprint;
  - `sysΔ` is the peak increase of system-wide used memory (active + wired + compressed) over the child's
    pre-load baseline. It captures ANE-resident weights that are not attributed to the process, but it is noisy.

## Capture qualification

- `Benchmarks/Capture/soak.sh <minutes> <busy-procs> <out.jsonl>`: loaded capture soak via the app's `capture-soak`.
- `Benchmarks/Capture/browser-matrix.sh <out-dir>`: Chrome/Firefox Web Audio playback trials.
- Results and manual checklists: `docs/qualification/`.
