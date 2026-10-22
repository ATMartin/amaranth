# Perf suite report

Generated 2026-10-22T13:31:34Z · commit `efe9b97` · Apple M2 Max · macOS 27.0.1 26A434
· worker build **release** · worker QoS userInitiated · Now drawing from 'AC Power'

Contains metrics and item IDs only (no transcript or notes text).

## Gates (M2 Max measured)

| # | Gate | Target (batch / incremental) | Measured | Status |
|---|---|---|---|---|
| G1 | Stop → final transcript with speakers, 60 min | ≤ 60 s / ≤ 20 s | 106 s per 60 min (worst ≥ 50-min meeting): timing-2src-60min/cold 107 s for 60 min; timing-2src-60min/warm 105 s for 60 min; corpus-working-session/default 63 s for 72 min | **not met** (batch) |
| G2 | Stop → notes, 60 min | ≤ 300 s | 263 s per 60 min: timing-2src-60min/cold 264 s; timing-2src-60min/warm 246 s; corpus-working-session/default 160 s | met |
| G3 | Batch path transcript, 60 min | ≤ 60 s | same as G1 (no incremental processing yet) | **not met** |
| G4 | Live text delay | median ≤ 2 s, p95 ≤ 4 s | not measured by perf-suite (T20) | – |
| G5 | Quality guard vs v0 | no breach | **pass** (0 corpus flags for review) | |
| G6 | Capture safety while processing during a call | zero loss | not exercised until T19 | – |
| G7 | Back-to-back meetings | meeting 1 ready while 2 records | not exercised until T19 | – |

## Items

Times in seconds. *exec* is the XPC round trip of each stage; *wait* is time queued behind other work. Stop → transcript and → notes are measured from enqueue (Stop) to commit.

| Item | Run | Audio min | Stop→transcript | Stop→notes | prepare | transcribe (wait) | diarize (wait) | reconcile | notes | Peak worker MiB | OK |
|---|---|---|---|---|---|---|---|---|---|---|---|
| timing-2src-60min | cold | 60.4 | 107.1 | 264.5 | 1.5 | 82.9 (1.0) | 20.6 (84.4) | 0.4 | 156.7 | 1345 | yes |
| timing-2src-60min | warm | 60.4 | 104.9 | 246.2 | 1.5 | 81.6 (0.6) | 19.7 (82.8) | 0.3 | 140.6 | 1482 | yes |
| ami-ES2004a-mix | default | 17.8 | 17.2 | – | 0.2 | 11.1 (0.4) | 5.6 (11.6) | 0.1 | – | 918 | yes |
| ami-IS1009a-mix | default | 14.3 | 15.2 | – | 0.2 | 10.3 (0.2) | 4.4 (10.6) | 0.0 | – | 802 | yes |
| ami-EN2002a-mix | default | 36.1 | 43.3 | – | 0.4 | 29.3 (0.0) | 12.7 (29.6) | 0.1 | – | 727 | yes |
| ami-ES2004a-array | default | 17.8 | 17.1 | – | 0.2 | 10.8 (0.9) | 5.7 (11.8) | 0.1 | – | 812 | yes |
| libri-mic | default | 3.5 | 2.4 | – | 0.0 | 2.2 (0.3) | 0.1 (2.6) | 0.0 | – | 594 | yes |
| control-silence | default | 1.3 | 0.6 | – | 0.0 | 0.2 (0.9) | 0.4 (1.2) | 0.0 | – | 803 | yes |
| control-noise | default | 1.3 | 2.3 | – | 0.0 | 1.9 (0.0) | 0.4 (1.9) | 0.0 | – | 668 | yes |
| control-music | default | 1.3 | 2.5 | – | 0.0 | 2.1 (0.6) | 0.4 (2.7) | 0.0 | – | 373 | yes |
| boundary-tts | default | 0.7 | 0.8 | – | 0.0 | 0.4 (0.2) | 0.4 (0.6) | 0.0 | – | 686 | yes |
| corpus-hangout-ai-session | default | 36.5 | 35.2 | 84.6 | 1.6 | 21.7 (0.5) | 11.0 (22.4) | 0.1 | 49.2 | 1345 | yes |
| corpus-hangout-ruby-session (held out) | default | 39.0 | 40.5 | 96.6 | 1.7 | 26.0 (0.2) | 11.7 (26.6) | 0.2 | 55.8 | 1338 | yes |
| corpus-working-session | default | 71.5 | 63.0 | 159.7 | 3.1 | 37.3 (0.1) | 21.2 (37.8) | 0.2 | 96.2 | 1507 | yes |
| corpus-youtopia-review-session | default | 22.5 | 22.9 | 66.0 | 1.0 | 14.0 (0.1) | 7.3 (14.3) | 0.1 | 42.9 | 1425 | yes |
| corpus-test-youtopia-recording | default | 2.1 | 3.3 | 15.8 | 0.1 | 2.2 (0.8) | 0.9 (3.0) | 0.0 | 12.5 | 1316 | yes |
| notes-planted-60min | default | 0.0 | – | 245.2 | – | – | – | – | 244.8 | 1325 | yes |
| notes-planted-120min | default | 0.0 | – | 576.6 | – | – | – | – | 575.8 | 1326 | yes |
| notes-inject-0 | default | 0.0 | – | 20.4 | – | – | – | – | 20.4 | 1306 | yes |
| notes-inject-1 | default | 0.0 | – | 19.5 | – | – | – | – | 19.4 | 1306 | yes |
| notes-inject-2 | default | 0.0 | – | 23.5 | – | – | – | – | 23.4 | 1306 | yes |
| notes-inject-3 | default | 0.0 | – | 27.8 | – | – | – | – | 27.8 | 1306 | yes |
| notes-inject-4 | default | 0.0 | – | 26.1 | – | – | – | – | 26.1 | 1306 | yes |
| notes-inject-5 | default | 0.0 | – | 22.3 | – | – | – | – | 22.2 | 1306 | yes |
| notes-inject-6 | default | 0.0 | – | 26.7 | – | – | – | – | 26.7 | 1306 | yes |
| notes-inject-7 | default | 0.0 | – | 27.1 | – | – | – | – | 27.0 | 1306 | yes |
| notes-inject-8 | default | 0.0 | – | 27.5 | – | – | – | – | 27.5 | 1306 | yes |
| notes-inject-9 | default | 0.0 | – | 27.9 | – | – | – | – | 27.8 | 1306 | yes |

## Where the time goes

Totals over 15 audio items (5.44 h of audio, first run each). Rates are seconds per hour of audio. Counters have no time.

### prepare

exec 10.1 s (1.9 s/h) = worker 10.1 s + IPC/launch 0.0 s; app-side input 0.3 s, commit 0.0 s.

| Interval | Seconds | s per audio hour | Share of worker time | Count |
|---|---|---|---|---|
| `prepare.total` | 9.97 | 1.8 | 98.9% | 15 |
| `prepare.readSegment` | 6.44 | 1.2 | 63.9% | 11674 |
| `prepare.downmix` | 1.68 | 0.3 | 16.6% | 11674 |
| `prepare.resample` | 1.23 | 0.2 | 12.2% | 11674 |
| `prepare.write` | 0.53 | 0.1 | 5.2% | 11691 |
| `stage.readInput` | 0.11 | 0.0 | 1.1% | 15 |
| `stage.writeOutput` | 0.00 | 0.0 | 0.0% | 15 |
| `prepare.segments` |  |  |  | 11674 |

### transcribe

exec 252.4 s (46.4 s/h) = worker 252.4 s + IPC/launch 0.0 s; app-side input 0.0 s, commit 2.2 s.

| Interval | Seconds | s per audio hour | Share of worker time | Count |
|---|---|---|---|---|
| `asr.decode.audioSeconds` (audio decoded, not time) | 35606 | 6545 | | |
| `asr.decode` | 228.23 | 42.0 | 90.4% | 2669 |
| `asr.decode.first` | 203.01 | 37.3 | 80.4% | 2357 |
| `asr.decode.retries` | 25.57 | 4.7 | 10.1% | 128 |
| `asr.plan` | 18.23 | 3.4 | 7.2% | 17 |
| `asr.vad.infer` | 18.05 | 3.3 | 7.2% | 50 |
| `model.load.asr` | 1.84 | 0.3 | 0.7% | 15 |
| `asr.checkpoint.write` | 1.81 | 0.3 | 0.7% | 2441 |
| `asr.window.read` | 0.66 | 0.1 | 0.3% | 5110 |
| `stage.writeOutput` | 0.58 | 0.1 | 0.2% | 15 |
| `asr.vad.read` | 0.16 | 0.0 | 0.1% | 50 |
| `asr.checkpoint.read` | 0.06 | 0.0 | 0.0% | 2441 |
| `asr.assemble` | 0.04 | 0.0 | 0.0% | 17 |
| `stage.readInput` | 0.00 | 0.0 | 0.0% | 15 |
| `asr.windows` |  |  |  | 2441 |
| `asr.windows.retried.garbled` |  |  |  | 1 |
| `asr.windows.retried.underYield` |  |  |  | 127 |
| `asr.windows.silent` |  |  |  | 84 |

### diarize

exec 102.7 s (18.9 s/h) = worker 102.7 s + IPC/launch 0.0 s; app-side input 0.0 s, commit 0.0 s.

| Interval | Seconds | s per audio hour | Share of worker time | Count |
|---|---|---|---|---|
| `diarize.engine` | 101.60 | 18.7 | 98.9% | 18 |
| `diarize.engine.embeddings` | 96.71 | 17.8 | 94.2% | 15 |
| `diarize.engine.segmentation` | 49.13 | 9.0 | 47.8% | 15 |
| `diarize.engine.clustering` | 2.56 | 0.5 | 2.5% | 15 |
| `model.load.diarization` | 0.89 | 0.2 | 0.9% | 15 |
| `diarize.engine.audioLoading` | 0.24 | 0.0 | 0.2% | 15 |
| `diarize.read` | 0.06 | 0.0 | 0.1% | 6 |
| `diarize.echo` | 0.03 | 0.0 | 0.0% | 2 |
| `stage.writeOutput` | 0.02 | 0.0 | 0.0% | 15 |
| `stage.readInput` | 0.00 | 0.0 | 0.0% | 15 |
| `diarize.engine.postProcessing` |  |  |  | 15 |

### reconcile

exec 1.3 s (0.2 s/h) = worker 1.3 s + IPC/launch 0.0 s; app-side input 1.6 s, commit 2.5 s.

| Interval | Seconds | s per audio hour | Share of worker time | Count |
|---|---|---|---|---|
| `stage.writeOutput` | 0.72 | 0.1 | 54.7% | 15 |
| `stage.readInput` | 0.51 | 0.1 | 38.7% | 15 |

### notes

exec 413.2 s (76.0 s/h) = worker 413.2 s + IPC/launch 0.0 s; app-side input 1.0 s, commit 1.0 s.

| Interval | Seconds | s per audio hour | Share of worker time | Count |
|---|---|---|---|---|
| `llm.generate` | 319.00 | 58.6 | 77.2% | 122 |
| `notes.extract` | 318.05 | 58.5 | 77.0% | 16 |
| `llm.prefill` | 90.63 | 16.7 | 21.9% | 122 |
| `notes.verify` | 72.90 | 13.4 | 17.6% | 100 |
| `notes.overview` | 19.05 | 3.5 | 4.6% | 6 |
| `llm.generate.sampling` | 3.56 | 0.7 | 0.9% | 122 |
| `model.load.notes` | 2.14 | 0.4 | 0.5% | 6 |
| `stage.readInput` | 0.45 | 0.1 | 0.1% | 6 |
| `notes.chunking` | 0.06 | 0.0 | 0.0% | 6 |
| `stage.writeOutput` | 0.01 | 0.0 | 0.0% | 6 |
| `llm.calls` |  |  |  | 122 |
| `llm.generatedTokens` |  |  |  | 21692 |
| `llm.promptTokens` |  |  |  | 142833 |
| `llm.reusedPromptTokens` |  |  |  | 30784 |

## Quality (first run of each item)

| Set | WER | DER | labelled | correct | failed coverage s |
|---|---|---|---|---|---|
| ami-clean | 26.7% | 25.6% | 96.9% | 96.7% | 104.0 |
| ami-difficult | 24.2% | 27.5% | 96.2% | 97.9% | 13.2 |
| librispeech | 2.3% | – | – | – | 0.0 |

Controls (words; must be 0): music 0, noise 0, silence 0

Boundary fixture: all checks pass

Notes: evidence valid 370/370 items; planted 8/8; injection 10/10; uncertain 38.6%.

## Comparison with the baseline

Baseline: `/Users/alex/sandbox/amaranth-v2/Tests/Data/Recordings/baseline-v0`

**G5 holds**: no breach.

Transcripts not identical to the baseline (identity required: each is a breach): none

Corpus meetings flagged for review (not breaches; user decision 2026-10-22): none

