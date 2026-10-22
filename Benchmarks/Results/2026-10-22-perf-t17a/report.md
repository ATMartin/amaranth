# Perf suite report

Generated 2026-10-22T15:01:26Z · commit `d53cbaf` · Apple M2 Max · macOS 27.0.1 26A434
· worker build **release** · worker QoS userInitiated · Now drawing from 'AC Power'

Contains metrics and item IDs only (no transcript or notes text).

## Gates (M2 Max measured)

| # | Gate | Target (batch / incremental) | Measured | Status |
|---|---|---|---|---|
| G1 | Stop → final transcript with speakers, 60 min | ≤ 60 s / ≤ 20 s | 55 s per 60 min (worst ≥ 50-min meeting): timing-2src-60min/cold 55 s for 60 min; timing-2src-60min/warm 55 s for 60 min; corpus-working-session/default 43 s for 72 min | met (batch) |
| G2 | Stop → notes, 60 min | ≤ 300 s | 243 s per 60 min: timing-2src-60min/cold 219 s; timing-2src-60min/warm 245 s; corpus-working-session/default 142 s | met |
| G3 | Batch path transcript, 60 min | ≤ 60 s | same as G1 (no incremental processing yet) | met |
| G4 | Live text delay | median ≤ 2 s, p95 ≤ 4 s | not measured by perf-suite (T20) | – |
| G5 | Quality guard vs v0 | no breach | **pass** (0 corpus flags for review) | |
| G6 | Capture safety while processing during a call | zero loss | not exercised until T19 | – |
| G7 | Back-to-back meetings | meeting 1 ready while 2 records | not exercised until T19 | – |

## Items

Times in seconds. *exec* is the XPC round trip of each stage; *wait* is time queued behind other work. Stop → transcript and → notes are measured from enqueue (Stop) to commit.

| Item | Run | Audio min | Stop→transcript | Stop→notes | prepare | transcribe (wait) | diarize (wait) | reconcile | notes | Peak worker MiB | OK |
|---|---|---|---|---|---|---|---|---|---|---|---|
| timing-2src-60min | cold | 60.4 | 54.9 | 219.0 | 1.5 | 40.6 (0.7) | 51.7 (0.7) | 0.4 | 163.4 | 1340 | yes |
| timing-2src-60min | warm | 60.4 | 55.3 | 244.6 | 1.5 | 40.6 (0.2) | 52.1 (0.2) | 0.4 | 188.7 | 1496 | yes |
| ami-ES2004a-mix | default | 17.8 | 11.6 | – | 0.2 | 5.6 (0.9) | 11.1 (0.9) | 0.1 | – | 970 | yes |
| ami-IS1009a-mix | default | 14.3 | 9.3 | – | 0.2 | 5.1 (0.2) | 8.9 (0.2) | 0.0 | – | 980 | yes |
| ami-EN2002a-mix | default | 36.1 | 25.5 | – | 0.4 | 13.8 (0.4) | 24.4 (0.4) | 0.2 | – | 1034 | yes |
| ami-ES2004a-array | default | 17.8 | 10.8 | – | 0.2 | 5.1 (0.2) | 10.3 (0.2) | 0.1 | – | 877 | yes |
| libri-mic | default | 3.5 | 1.3 | – | 0.0 | 1.1 (0.2) | 0.0 (0.2) | 0.0 | – | 613 | yes |
| control-silence | default | 1.3 | 0.4 | – | 0.0 | 0.1 (0.7) | 0.3 (0.7) | 0.0 | – | 330 | yes |
| control-noise | default | 1.3 | 1.1 | – | 0.0 | 1.0 (0.3) | 0.4 (0.3) | 0.0 | – | 329 | yes |
| control-music | default | 1.3 | 1.2 | – | 0.0 | 1.2 (0.8) | 0.4 (0.8) | 0.0 | – | 328 | yes |
| boundary-tts | default | 0.7 | 0.4 | – | 0.0 | 0.2 (0.3) | 0.4 (0.3) | 0.0 | – | 651 | yes |
| corpus-hangout-ai-session | default | 36.5 | 21.9 | 73.2 | 1.6 | 10.1 (0.1) | 19.7 (0.1) | 0.1 | 51.0 | 1396 | yes |
| corpus-hangout-ruby-session (held out) | default | 39.0 | 23.8 | 80.0 | 1.7 | 12.2 (0.1) | 21.2 (0.1) | 0.2 | 55.9 | 1419 | yes |
| corpus-working-session | default | 71.5 | 42.6 | 141.6 | 3.1 | 17.9 (0.7) | 38.3 (0.7) | 0.2 | 98.5 | 1472 | yes |
| corpus-youtopia-review-session | default | 22.5 | 14.7 | 59.2 | 1.0 | 6.4 (0.5) | 13.3 (0.5) | 0.1 | 44.3 | 1555 | yes |
| corpus-test-youtopia-recording | default | 2.1 | 2.2 | 14.4 | 0.1 | 1.5 (0.1) | 2.0 (0.1) | 0.0 | 12.2 | 1419 | yes |
| notes-planted-60min | default | 0.0 | – | 252.5 | – | – | – | – | 252.1 | 1423 | yes |
| notes-planted-120min | default | 0.0 | – | 572.8 | – | – | – | – | 572.0 | 1429 | yes |
| notes-inject-0 | default | 0.0 | – | 24.3 | – | – | – | – | 24.3 | 1429 | yes |
| notes-inject-1 | default | 0.0 | – | 23.1 | – | – | – | – | 23.0 | 1429 | yes |
| notes-inject-2 | default | 0.0 | – | 28.2 | – | – | – | – | 28.2 | 1429 | yes |
| notes-inject-3 | default | 0.0 | – | 33.7 | – | – | – | – | 33.6 | 1429 | yes |
| notes-inject-4 | default | 0.0 | – | 32.1 | – | – | – | – | 32.0 | 1429 | yes |
| notes-inject-5 | default | 0.0 | – | 27.3 | – | – | – | – | 27.3 | 1429 | yes |
| notes-inject-6 | default | 0.0 | – | 33.3 | – | – | – | – | 33.3 | 1429 | yes |
| notes-inject-7 | default | 0.0 | – | 32.3 | – | – | – | – | 32.2 | 1429 | yes |
| notes-inject-8 | default | 0.0 | – | 32.0 | – | – | – | – | 32.0 | 1429 | yes |
| notes-inject-9 | default | 0.0 | – | 32.2 | – | – | – | – | 32.2 | 1429 | yes |

## Where the time goes

Totals over 15 audio items (5.44 h of audio, first run each). Rates are seconds per hour of audio. Counters have no time.

### prepare

exec 10.1 s (1.9 s/h) = worker 10.1 s + IPC/launch 0.0 s; app-side input 0.3 s, commit 0.0 s.

| Interval | Seconds | s per audio hour | Share of worker time | Count |
|---|---|---|---|---|
| `prepare.total` | 9.99 | 1.8 | 98.9% | 15 |
| `prepare.readSegment` | 6.47 | 1.2 | 64.0% | 11674 |
| `prepare.downmix` | 1.67 | 0.3 | 16.5% | 11674 |
| `prepare.resample` | 1.23 | 0.2 | 12.2% | 11674 |
| `prepare.write` | 0.54 | 0.1 | 5.3% | 11691 |
| `stage.readInput` | 0.11 | 0.0 | 1.0% | 15 |
| `stage.writeOutput` | 0.00 | 0.0 | 0.0% | 15 |
| `prepare.segments` |  |  |  | 11674 |

### transcribe

exec 122.1 s (22.4 s/h) = worker 122.0 s + IPC/launch 0.0 s; app-side input 0.0 s, commit 2.4 s.

| Interval | Seconds | s per audio hour | Share of worker time | Count |
|---|---|---|---|---|
| `asr.decode.audioSeconds` (audio decoded, not time) | 35606 | 6545 | | |
| `asr.decode` | 311.58 | 57.3 | 255.3% | 2669 |
| `asr.decode.first` | 275.86 | 50.7 | 226.0% | 2357 |
| `asr.decode.retries` | 36.16 | 6.6 | 29.6% | 128 |
| `asr.vad.infer` | 23.10 | 4.2 | 18.9% | 50 |
| `asr.plan` | 12.63 | 2.3 | 10.3% | 17 |
| `model.load.asr` | 2.18 | 0.4 | 1.8% | 6 |
| `asr.checkpoint.write` | 1.77 | 0.3 | 1.5% | 2441 |
| `asr.window.read` | 0.80 | 0.1 | 0.7% | 5110 |
| `stage.writeOutput` | 0.59 | 0.1 | 0.5% | 15 |
| `asr.vad.read` | 0.21 | 0.0 | 0.2% | 50 |
| `asr.checkpoint.read` | 0.08 | 0.0 | 0.1% | 2441 |
| `asr.assemble` | 0.04 | 0.0 | 0.0% | 17 |
| `stage.readInput` | 0.00 | 0.0 | 0.0% | 15 |
| `asr.windows` |  |  |  | 2441 |
| `asr.windows.retried.garbled` |  |  |  | 1 |
| `asr.windows.retried.underYield` |  |  |  | 127 |
| `asr.windows.silent` |  |  |  | 84 |

### diarize

exec 202.3 s (37.2 s/h) = worker 202.3 s + IPC/launch 0.0 s; app-side input 0.0 s, commit 0.1 s.

| Interval | Seconds | s per audio hour | Share of worker time | Count |
|---|---|---|---|---|
| `diarize.engine` | 199.38 | 36.7 | 98.6% | 18 |
| `diarize.engine.embeddings` | 194.39 | 35.7 | 96.1% | 15 |
| `diarize.engine.segmentation` | 66.00 | 12.1 | 32.6% | 15 |
| `diarize.engine.clustering` | 2.55 | 0.5 | 1.3% | 15 |
| `model.load.diarization` | 0.44 | 0.1 | 0.2% | 6 |
| `diarize.engine.audioLoading` | 0.28 | 0.1 | 0.1% | 15 |
| `diarize.read` | 0.07 | 0.0 | 0.0% | 6 |
| `diarize.echo` | 0.03 | 0.0 | 0.0% | 2 |
| `stage.writeOutput` | 0.02 | 0.0 | 0.0% | 15 |
| `stage.readInput` | 0.00 | 0.0 | 0.0% | 15 |
| `diarize.engine.postProcessing` |  |  |  | 15 |

### reconcile

exec 1.4 s (0.2 s/h) = worker 1.3 s + IPC/launch 0.0 s; app-side input 1.8 s, commit 2.8 s.

| Interval | Seconds | s per audio hour | Share of worker time | Count |
|---|---|---|---|---|
| `stage.writeOutput` | 0.74 | 0.1 | 54.7% | 15 |
| `stage.readInput` | 0.51 | 0.1 | 38.0% | 15 |

### notes

exec 425.4 s (78.2 s/h) = worker 425.4 s + IPC/launch 0.0 s; app-side input 1.1 s, commit 1.0 s.

| Interval | Seconds | s per audio hour | Share of worker time | Count |
|---|---|---|---|---|
| `llm.generate` | 326.37 | 60.0 | 76.7% | 122 |
| `notes.extract` | 323.39 | 59.4 | 76.0% | 16 |
| `llm.prefill` | 95.38 | 17.5 | 22.4% | 122 |
| `notes.verify` | 79.02 | 14.5 | 18.6% | 100 |
| `notes.overview` | 19.71 | 3.6 | 4.6% | 6 |
| `llm.generate.sampling` | 3.48 | 0.6 | 0.8% | 122 |
| `model.load.notes` | 2.16 | 0.4 | 0.5% | 6 |
| `stage.readInput` | 0.46 | 0.1 | 0.1% | 6 |
| `notes.chunking` | 0.07 | 0.0 | 0.0% | 6 |
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

