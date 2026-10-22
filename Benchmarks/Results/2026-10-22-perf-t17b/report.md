# Perf suite report

Generated 2026-10-22T15:54:29Z · commit `d53cbaf` · Apple M2 Max · macOS 27.0.1 26A434
· worker build **release** · worker QoS userInitiated · Now drawing from 'Battery Power'

Contains metrics and item IDs only (no transcript or notes text).

## Gates (M2 Max measured)

| # | Gate | Target (batch / incremental) | Measured | Status |
|---|---|---|---|---|
| G1 | Stop → final transcript with speakers, 60 min | ≤ 60 s / ≤ 20 s | 53 s per 60 min (worst ≥ 50-min meeting): timing-2src-60min/cold 54 s for 60 min; timing-2src-60min/warm 53 s for 60 min; corpus-working-session/default 40 s for 72 min | met (batch) |
| G2 | Stop → notes, 60 min | ≤ 300 s | 250 s per 60 min: timing-2src-60min/cold 206 s; timing-2src-60min/warm 252 s; corpus-working-session/default 152 s | met |
| G3 | Batch path transcript, 60 min | ≤ 60 s | same as G1 (no incremental processing yet) | met |
| G4 | Live text delay | median ≤ 2 s, p95 ≤ 4 s | not measured by perf-suite (T20) | – |
| G5 | Quality guard vs v0 | no breach | **pass** (0 corpus flags for review) | |
| G6 | Capture safety while processing during a call | zero loss | not exercised until T19 | – |
| G7 | Back-to-back meetings | meeting 1 ready while 2 records | not exercised until T19 | – |

## Items

Times in seconds. *exec* is the XPC round trip of each stage; *wait* is time queued behind other work. Stop → transcript and → notes are measured from enqueue (Stop) to commit.

| Item | Run | Audio min | Stop→transcript | Stop→notes | prepare | transcribe (wait) | diarize (wait) | reconcile | notes | Peak worker MiB | OK |
|---|---|---|---|---|---|---|---|---|---|---|---|
| timing-2src-60min | cold | 60.4 | 53.8 | 206.0 | 1.5 | 50.0 (0.5) | 45.1 (0.5) | 0.4 | 151.5 | 1368 | yes |
| timing-2src-60min | warm | 60.4 | 53.1 | 251.5 | 1.5 | 49.4 (0.9) | 45.5 (0.9) | 0.4 | 197.6 | 1461 | yes |
| ami-ES2004a-mix | default | 17.8 | 10.9 | – | 0.2 | 7.7 (0.3) | 10.4 (0.3) | 0.1 | – | 978 | yes |
| ami-IS1009a-mix | default | 14.3 | 8.7 | – | 0.2 | 6.7 (0.6) | 8.3 (0.6) | 0.0 | – | 976 | yes |
| ami-EN2002a-mix | default | 36.1 | 23.6 | – | 0.4 | 18.4 (0.3) | 22.5 (0.3) | 0.1 | – | 1031 | yes |
| ami-ES2004a-array | default | 17.8 | 10.4 | – | 0.2 | 6.6 (0.7) | 9.9 (0.7) | 0.1 | – | 868 | yes |
| libri-mic | default | 3.5 | 1.4 | – | 0.0 | 1.3 (0.2) | 0.0 (0.2) | 0.0 | – | 515 | yes |
| control-silence | default | 1.3 | 0.4 | – | 0.0 | 0.1 (0.7) | 0.4 (0.7) | 0.0 | – | 333 | yes |
| control-noise | default | 1.3 | 1.2 | – | 0.0 | 1.2 (0.2) | 0.4 (0.2) | 0.0 | – | 332 | yes |
| control-music | default | 1.3 | 1.2 | – | 0.0 | 1.2 (0.7) | 0.4 (0.7) | 0.0 | – | 332 | yes |
| boundary-tts | default | 0.7 | 0.4 | – | 0.0 | 0.3 (0.3) | 0.4 (0.3) | 0.0 | – | 655 | yes |
| corpus-hangout-ai-session | default | 36.5 | 20.5 | 80.5 | 1.6 | 13.3 (0.1) | 18.2 (0.1) | 0.1 | 59.7 | 1414 | yes |
| corpus-hangout-ruby-session (held out) | default | 39.0 | 21.9 | 86.1 | 1.7 | 15.8 (0.0) | 19.3 (0.0) | 0.2 | 63.8 | 1435 | yes |
| corpus-working-session | default | 71.5 | 40.5 | 152.5 | 3.1 | 22.9 (0.4) | 36.2 (0.4) | 0.2 | 111.5 | 1379 | yes |
| corpus-youtopia-review-session | default | 22.5 | 13.5 | 62.0 | 1.0 | 7.8 (0.1) | 12.1 (0.1) | 0.1 | 48.3 | 1434 | yes |
| corpus-test-youtopia-recording | default | 2.1 | 2.0 | 15.4 | 0.1 | 1.5 (0.7) | 1.8 (0.7) | 0.0 | 13.4 | 1347 | yes |
| notes-planted-60min | default | 0.0 | – | 269.6 | – | – | – | – | 269.2 | 1352 | yes |
| notes-planted-120min | default | 0.0 | – | 604.9 | – | – | – | – | 604.1 | 1358 | yes |
| notes-inject-0 | default | 0.0 | – | 24.9 | – | – | – | – | 24.8 | 1358 | yes |
| notes-inject-1 | default | 0.0 | – | 23.6 | – | – | – | – | 23.6 | 1358 | yes |
| notes-inject-2 | default | 0.0 | – | 28.7 | – | – | – | – | 28.7 | 1358 | yes |
| notes-inject-3 | default | 0.0 | – | 34.3 | – | – | – | – | 34.2 | 1358 | yes |
| notes-inject-4 | default | 0.0 | – | 32.0 | – | – | – | – | 32.0 | 1358 | yes |
| notes-inject-5 | default | 0.0 | – | 27.5 | – | – | – | – | 27.4 | 1358 | yes |
| notes-inject-6 | default | 0.0 | – | 33.3 | – | – | – | – | 33.2 | 1358 | yes |
| notes-inject-7 | default | 0.0 | – | 33.0 | – | – | – | – | 32.9 | 1358 | yes |
| notes-inject-8 | default | 0.0 | – | 32.9 | – | – | – | – | 32.8 | 1358 | yes |
| notes-inject-9 | default | 0.0 | – | 32.6 | – | – | – | – | 32.5 | 1358 | yes |

## Where the time goes

Totals over 15 audio items (5.44 h of audio, first run each). Rates are seconds per hour of audio. Counters have no time.

### prepare

exec 10.3 s (1.9 s/h) = worker 10.2 s + IPC/launch 0.0 s; app-side input 0.3 s, commit 0.0 s.

| Interval | Seconds | s per audio hour | Share of worker time | Count |
|---|---|---|---|---|
| `prepare.total` | 10.13 | 1.9 | 98.8% | 15 |
| `prepare.readSegment` | 6.56 | 1.2 | 64.0% | 11674 |
| `prepare.downmix` | 1.67 | 0.3 | 16.3% | 11674 |
| `prepare.resample` | 1.24 | 0.2 | 12.1% | 11674 |
| `prepare.write` | 0.56 | 0.1 | 5.4% | 11691 |
| `stage.readInput` | 0.11 | 0.0 | 1.1% | 15 |
| `stage.writeOutput` | 0.00 | 0.0 | 0.0% | 15 |
| `prepare.segments` |  |  |  | 11674 |

### transcribe

exec 154.5 s (28.4 s/h) = worker 154.5 s + IPC/launch 0.0 s; app-side input 0.0 s, commit 2.4 s.

| Interval | Seconds | s per audio hour | Share of worker time | Count |
|---|---|---|---|---|
| `asr.decode.audioSeconds` (audio decoded, not time) | 35606 | 6545 | | |
| `asr.decode` | 272.83 | 50.2 | 176.6% | 2669 |
| `asr.decode.first` | 241.44 | 44.4 | 156.3% | 2357 |
| `asr.decode.retries` | 31.82 | 5.8 | 20.6% | 128 |
| `asr.vad.infer` | 23.56 | 4.3 | 15.3% | 50 |
| `asr.plan` | 13.00 | 2.4 | 8.4% | 17 |
| `asr.checkpoint.write` | 1.83 | 0.3 | 1.2% | 2441 |
| `model.load.asr` | 1.58 | 0.3 | 1.0% | 6 |
| `asr.window.read` | 0.78 | 0.1 | 0.5% | 5110 |
| `stage.writeOutput` | 0.63 | 0.1 | 0.4% | 15 |
| `asr.vad.read` | 0.21 | 0.0 | 0.1% | 50 |
| `asr.checkpoint.read` | 0.08 | 0.0 | 0.1% | 2441 |
| `asr.assemble` | 0.04 | 0.0 | 0.0% | 17 |
| `stage.readInput` | 0.00 | 0.0 | 0.0% | 15 |
| `asr.windows` |  |  |  | 2441 |
| `asr.windows.retried.garbled` |  |  |  | 1 |
| `asr.windows.retried.underYield` |  |  |  | 127 |
| `asr.windows.silent` |  |  |  | 84 |

### diarize

exec 185.3 s (34.1 s/h) = worker 185.3 s + IPC/launch 0.0 s; app-side input 0.0 s, commit 0.1 s.

| Interval | Seconds | s per audio hour | Share of worker time | Count |
|---|---|---|---|---|
| `diarize.engine` | 183.01 | 33.6 | 98.8% | 18 |
| `diarize.engine.embeddings` | 177.96 | 32.7 | 96.0% | 15 |
| `diarize.engine.segmentation` | 65.70 | 12.1 | 35.5% | 15 |
| `diarize.engine.clustering` | 2.58 | 0.5 | 1.4% | 15 |
| `model.load.diarization` | 0.43 | 0.1 | 0.2% | 6 |
| `diarize.engine.audioLoading` | 0.28 | 0.1 | 0.1% | 15 |
| `diarize.read` | 0.07 | 0.0 | 0.0% | 6 |
| `diarize.echo` | 0.03 | 0.0 | 0.0% | 2 |
| `stage.writeOutput` | 0.02 | 0.0 | 0.0% | 15 |
| `stage.readInput` | 0.00 | 0.0 | 0.0% | 15 |
| `diarize.engine.postProcessing` |  |  |  | 15 |

### reconcile

exec 1.3 s (0.2 s/h) = worker 1.3 s + IPC/launch 0.0 s; app-side input 1.8 s, commit 2.8 s.

| Interval | Seconds | s per audio hour | Share of worker time | Count |
|---|---|---|---|---|
| `stage.writeOutput` | 0.74 | 0.1 | 55.1% | 15 |
| `stage.readInput` | 0.51 | 0.1 | 38.2% | 15 |

### notes

exec 448.3 s (82.4 s/h) = worker 448.3 s + IPC/launch 0.0 s; app-side input 1.1 s, commit 1.0 s.

| Interval | Seconds | s per audio hour | Share of worker time | Count |
|---|---|---|---|---|
| `llm.generate` | 343.25 | 63.1 | 76.6% | 122 |
| `notes.extract` | 342.24 | 62.9 | 76.3% | 16 |
| `llm.prefill` | 101.37 | 18.6 | 22.6% | 122 |
| `notes.verify` | 82.07 | 15.1 | 18.3% | 100 |
| `notes.overview` | 20.69 | 3.8 | 4.6% | 6 |
| `llm.generate.sampling` | 3.55 | 0.7 | 0.8% | 122 |
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

