# Perf suite report

Generated 2026-10-22T10:59:50Z · commit `efe9b97` · Apple M2 Max · macOS 27.0.1 26A434
· worker build **debug** · worker QoS userInitiated · Now drawing from 'AC Power'

Contains metrics and item IDs only (no transcript or notes text).

## Gates (M2 Max measured)

| # | Gate | Target (batch / incremental) | Measured | Status |
|---|---|---|---|---|
| G1 | Stop → final transcript with speakers, 60 min | ≤ 60 s / ≤ 20 s | 290 s per 60 min (worst ≥ 50-min meeting): timing-2src-60min/cold 292 s for 60 min; timing-2src-60min/warm 285 s for 60 min | **not met** (batch) |
| G2 | Stop → notes, 60 min | ≤ 300 s | 581 s per 60 min: timing-2src-60min/cold 570 s; timing-2src-60min/warm 585 s | **not met** |
| G3 | Batch path transcript, 60 min | ≤ 60 s | same as G1 (no incremental processing yet) | **not met** |
| G4 | Live text delay | median ≤ 2 s, p95 ≤ 4 s | not measured by perf-suite (T20) | – |
| G5 | Quality guard vs v0 | no breach | not compared (run with `--compare <baseline>`) | |
| G6 | Capture safety while processing during a call | zero loss | not exercised until T19 | – |
| G7 | Back-to-back meetings | meeting 1 ready while 2 records | not exercised until T19 | – |

## Items

Times in seconds. *exec* is the XPC round trip of each stage; *wait* is time queued behind other work. Stop → transcript and → notes are measured from enqueue (Stop) to commit.

| Item | Run | Audio min | Stop→transcript | Stop→notes | prepare | transcribe (wait) | diarize (wait) | reconcile | notes | Peak worker MiB | OK |
|---|---|---|---|---|---|---|---|---|---|---|---|
| timing-2src-60min | cold | 60.4 | 292.2 | 569.7 | 34.6 | 181.7 (1.0) | 73.1 (183.3) | 0.9 | 276.8 | 1338 | yes |
| timing-2src-60min | warm | 60.4 | 284.6 | 584.6 | 32.8 | 176.6 (0.8) | 72.4 (178.0) | 0.9 | 299.3 | 1493 | yes |

## Where the time goes

Totals over 1 audio items (1.01 h of audio, first run each). Rates are seconds per hour of audio. Counters have no time.

### prepare

exec 34.6 s (34.3 s/h) = worker 34.6 s + IPC/launch 0.0 s; app-side input 0.1 s, commit 0.0 s.

| Interval | Seconds | s per audio hour | Share of worker time | Count |
|---|---|---|---|---|
| `prepare.total` | 34.52 | 34.3 | 99.9% | 1 |
| `prepare.write` | 19.78 | 19.6 | 57.3% | 3628 |
| `prepare.readSegment` | 14.26 | 14.2 | 41.3% | 3626 |
| `stage.readInput` | 0.04 | 0.0 | 0.1% | 1 |
| `prepare.resample` | 0.00 | 0.0 | 0.0% | 3626 |
| `prepare.downmix` | 0.00 | 0.0 | 0.0% | 3626 |
| `stage.writeOutput` | 0.00 | 0.0 | 0.0% | 1 |
| `prepare.segments` |  |  |  | 3626 |

### transcribe

exec 181.7 s (180.5 s/h) = worker 181.7 s + IPC/launch 0.0 s; app-side input 0.0 s, commit 0.6 s.

| Interval | Seconds | s per audio hour | Share of worker time | Count |
|---|---|---|---|---|
| `asr.decode.audioSeconds` (audio decoded, not time) | 11860 | 11778 | | |
| `asr.decode.first` | 114.32 | 113.5 | 62.9% | 787 |
| `asr.decode` | 101.78 | 101.1 | 56.0% | 913 |
| `asr.window.read` | 47.26 | 46.9 | 26.0% | 1705 |
| `asr.plan` | 23.57 | 23.4 | 13.0% | 2 |
| `asr.vad.read` | 17.79 | 17.7 | 9.8% | 14 |
| `asr.decode.retries` | 16.79 | 16.7 | 9.2% | 52 |
| `asr.vad.infer` | 5.74 | 5.7 | 3.2% | 14 |
| `asr.checkpoint.write` | 0.62 | 0.6 | 0.3% | 792 |
| `stage.writeOutput` | 0.16 | 0.2 | 0.1% | 1 |
| `model.load.asr` | 0.13 | 0.1 | 0.1% | 1 |
| `asr.assemble` | 0.04 | 0.0 | 0.0% | 2 |
| `asr.checkpoint.read` | 0.02 | 0.0 | 0.0% | 792 |
| `stage.readInput` | 0.00 | 0.0 | 0.0% | 1 |
| `asr.windows` |  |  |  | 792 |
| `asr.windows.retried.garbled` |  |  |  | 1 |
| `asr.windows.retried.underYield` |  |  |  | 51 |
| `asr.windows.silent` |  |  |  | 5 |

### diarize

exec 73.1 s (72.6 s/h) = worker 73.1 s + IPC/launch 0.0 s; app-side input 0.0 s, commit 0.0 s.

| Interval | Seconds | s per audio hour | Share of worker time | Count |
|---|---|---|---|---|
| `diarize.engine` | 60.82 | 60.4 | 83.2% | 3 |
| `diarize.engine.embeddings` | 55.06 | 54.7 | 75.3% | 2 |
| `diarize.engine.segmentation` | 14.47 | 14.4 | 19.8% | 2 |
| `diarize.read` | 8.48 | 8.4 | 11.6% | 3 |
| `diarize.echo` | 3.72 | 3.7 | 5.1% | 1 |
| `diarize.engine.clustering` | 2.45 | 2.4 | 3.4% | 2 |
| `model.load.diarization` | 0.08 | 0.1 | 0.1% | 1 |
| `stage.writeOutput` | 0.00 | 0.0 | 0.0% | 1 |
| `stage.readInput` | 0.00 | 0.0 | 0.0% | 1 |
| `diarize.engine.audioLoading` |  |  |  | 2 |
| `diarize.engine.postProcessing` |  |  |  | 2 |

### reconcile

exec 0.9 s (0.9 s/h) = worker 0.9 s + IPC/launch 0.0 s; app-side input 0.5 s, commit 0.7 s.

| Interval | Seconds | s per audio hour | Share of worker time | Count |
|---|---|---|---|---|
| `stage.writeOutput` | 0.20 | 0.2 | 22.6% | 1 |
| `stage.readInput` | 0.14 | 0.1 | 16.7% | 1 |

### notes

exec 276.8 s (274.8 s/h) = worker 276.8 s + IPC/launch 0.0 s; app-side input 0.4 s, commit 0.4 s.

| Interval | Seconds | s per audio hour | Share of worker time | Count |
|---|---|---|---|---|
| `llm.generate` | 238.45 | 236.8 | 86.2% | 44 |
| `notes.extract` | 228.15 | 226.6 | 82.4% | 6 |
| `llm.generate.sampling` | 114.68 | 113.9 | 41.4% | 44 |
| `notes.verify` | 41.19 | 40.9 | 14.9% | 37 |
| `llm.prefill` | 37.36 | 37.1 | 13.5% | 44 |
| `notes.overview` | 6.58 | 6.5 | 2.4% | 1 |
| `model.load.notes` | 0.36 | 0.4 | 0.1% | 1 |
| `stage.readInput` | 0.17 | 0.2 | 0.1% | 1 |
| `notes.chunking` | 0.03 | 0.0 | 0.0% | 1 |
| `stage.writeOutput` | 0.00 | 0.0 | 0.0% | 1 |
| `llm.calls` |  |  |  | 44 |
| `llm.generatedTokens` |  |  |  | 7529 |
| `llm.promptTokens` |  |  |  | 52938 |
| `llm.reusedPromptTokens` |  |  |  | 12389 |

## Quality (first run of each item)

| Set | WER | DER | labelled | correct | failed coverage s |
|---|---|---|---|---|---|

Controls (words; must be 0): 

Boundary fixture: not run

