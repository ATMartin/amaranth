# Perf suite report

Generated 2026-10-22T15:10:12Z · commit `d53cbaf` · Apple M2 Max · macOS 27.0.1 26A434
· worker build **release** · worker QoS userInitiated · Now drawing from 'AC Power'

Contains metrics and item IDs only (no transcript or notes text).

## Gates (M2 Max measured)

| # | Gate | Target (batch / incremental) | Measured | Status |
|---|---|---|---|---|
| G1 | Stop → final transcript with speakers, 60 min | ≤ 60 s / ≤ 20 s | 54 s per 60 min (worst ≥ 50-min meeting): timing-2src-60min/cold 54 s for 60 min; timing-2src-60min/warm 53 s for 60 min | met (batch) |
| G2 | Stop → notes, 60 min | ≤ 300 s | 248 s per 60 min: timing-2src-60min/cold 207 s; timing-2src-60min/warm 250 s | met |
| G3 | Batch path transcript, 60 min | ≤ 60 s | same as G1 (no incremental processing yet) | met |
| G4 | Live text delay | median ≤ 2 s, p95 ≤ 4 s | not measured by perf-suite (T20) | – |
| G5 | Quality guard vs v0 | no breach | **pass** (0 corpus flags for review) | |
| G6 | Capture safety while processing during a call | zero loss | not exercised until T19 | – |
| G7 | Back-to-back meetings | meeting 1 ready while 2 records | not exercised until T19 | – |

## Items

Times in seconds. *exec* is the XPC round trip of each stage; *wait* is time queued behind other work. Stop → transcript and → notes are measured from enqueue (Stop) to commit.

| Item | Run | Audio min | Stop→transcript | Stop→notes | prepare | transcribe (wait) | diarize (wait) | reconcile | notes | Peak worker MiB | OK |
|---|---|---|---|---|---|---|---|---|---|---|---|
| timing-2src-60min | cold | 60.4 | 54.4 | 207.0 | 1.5 | 50.7 (0.4) | 44.7 (0.4) | 0.4 | 151.9 | 1368 | yes |
| timing-2src-60min | warm | 60.4 | 53.1 | 249.9 | 1.5 | 49.3 (0.8) | 44.6 (0.8) | 0.3 | 196.1 | 1457 | yes |

## Where the time goes

Totals over 1 audio items (1.01 h of audio, first run each). Rates are seconds per hour of audio. Counters have no time.

### prepare

exec 1.5 s (1.5 s/h) = worker 1.5 s + IPC/launch 0.0 s; app-side input 0.1 s, commit 0.0 s.

| Interval | Seconds | s per audio hour | Share of worker time | Count |
|---|---|---|---|---|
| `prepare.total` | 1.43 | 1.4 | 97.6% | 1 |
| `prepare.readSegment` | 1.21 | 1.2 | 82.7% | 3626 |
| `prepare.write` | 0.18 | 0.2 | 12.5% | 3628 |
| `stage.readInput` | 0.03 | 0.0 | 2.3% | 1 |
| `prepare.resample` | 0.00 | 0.0 | 0.1% | 3626 |
| `prepare.downmix` | 0.00 | 0.0 | 0.1% | 3626 |
| `stage.writeOutput` | 0.00 | 0.0 | 0.0% | 1 |
| `prepare.segments` |  |  |  | 3626 |

### transcribe

exec 50.7 s (50.3 s/h) = worker 50.7 s + IPC/launch 0.0 s; app-side input 0.0 s, commit 0.6 s.

| Interval | Seconds | s per audio hour | Share of worker time | Count |
|---|---|---|---|---|
| `asr.decode.audioSeconds` (audio decoded, not time) | 11860 | 11778 | | |
| `asr.decode` | 91.58 | 90.9 | 180.8% | 913 |
| `asr.decode.first` | 79.36 | 78.8 | 156.7% | 787 |
| `asr.decode.retries` | 12.36 | 12.3 | 24.4% | 52 |
| `asr.vad.infer` | 7.34 | 7.3 | 14.5% | 14 |
| `asr.plan` | 3.74 | 3.7 | 7.4% | 2 |
| `asr.checkpoint.write` | 0.62 | 0.6 | 1.2% | 792 |
| `model.load.asr` | 0.27 | 0.3 | 0.5% | 1 |
| `asr.window.read` | 0.26 | 0.3 | 0.5% | 1705 |
| `stage.writeOutput` | 0.17 | 0.2 | 0.3% | 1 |
| `asr.vad.read` | 0.07 | 0.1 | 0.1% | 14 |
| `asr.checkpoint.read` | 0.03 | 0.0 | 0.1% | 792 |
| `asr.assemble` | 0.01 | 0.0 | 0.0% | 2 |
| `stage.readInput` | 0.00 | 0.0 | 0.0% | 1 |
| `asr.windows` |  |  |  | 792 |
| `asr.windows.retried.garbled` |  |  |  | 1 |
| `asr.windows.retried.underYield` |  |  |  | 51 |
| `asr.windows.silent` |  |  |  | 5 |

### diarize

exec 44.7 s (44.4 s/h) = worker 44.7 s + IPC/launch 0.0 s; app-side input 0.0 s, commit 0.0 s.

| Interval | Seconds | s per audio hour | Share of worker time | Count |
|---|---|---|---|---|
| `diarize.engine` | 44.28 | 44.0 | 99.0% | 3 |
| `diarize.engine.embeddings` | 43.17 | 42.9 | 96.5% | 2 |
| `diarize.engine.segmentation` | 12.64 | 12.6 | 28.3% | 2 |
| `diarize.engine.clustering` | 0.62 | 0.6 | 1.4% | 2 |
| `model.load.diarization` | 0.10 | 0.1 | 0.2% | 1 |
| `diarize.read` | 0.03 | 0.0 | 0.1% | 3 |
| `diarize.echo` | 0.03 | 0.0 | 0.1% | 1 |
| `stage.writeOutput` | 0.00 | 0.0 | 0.0% | 1 |
| `stage.readInput` | 0.00 | 0.0 | 0.0% | 1 |
| `diarize.engine.audioLoading` |  |  |  | 2 |
| `diarize.engine.postProcessing` |  |  |  | 2 |

### reconcile

exec 0.4 s (0.4 s/h) = worker 0.4 s + IPC/launch 0.0 s; app-side input 0.5 s, commit 0.7 s.

| Interval | Seconds | s per audio hour | Share of worker time | Count |
|---|---|---|---|---|
| `stage.writeOutput` | 0.19 | 0.2 | 53.6% | 1 |
| `stage.readInput` | 0.14 | 0.1 | 40.1% | 1 |

### notes

exec 151.9 s (150.8 s/h) = worker 151.9 s + IPC/launch 0.0 s; app-side input 0.4 s, commit 0.3 s.

| Interval | Seconds | s per audio hour | Share of worker time | Count |
|---|---|---|---|---|
| `notes.extract` | 118.49 | 117.7 | 78.0% | 6 |
| `llm.generate` | 115.24 | 114.4 | 75.9% | 45 |
| `llm.prefill` | 35.70 | 35.5 | 23.5% | 45 |
| `notes.verify` | 28.42 | 28.2 | 18.7% | 38 |
| `notes.overview` | 4.16 | 4.1 | 2.7% | 1 |
| `llm.generate.sampling` | 1.15 | 1.1 | 0.8% | 45 |
| `model.load.notes` | 0.39 | 0.4 | 0.3% | 1 |
| `stage.readInput` | 0.16 | 0.2 | 0.1% | 1 |
| `notes.chunking` | 0.02 | 0.0 | 0.0% | 1 |
| `stage.writeOutput` | 0.00 | 0.0 | 0.0% | 1 |
| `llm.calls` |  |  |  | 45 |
| `llm.generatedTokens` |  |  |  | 7594 |
| `llm.promptTokens` |  |  |  | 54472 |
| `llm.reusedPromptTokens` |  |  |  | 12444 |

## Quality (first run of each item)

| Set | WER | DER | labelled | correct | failed coverage s |
|---|---|---|---|---|---|

Controls (words; must be 0): 

Boundary fixture: not run

## Comparison with the baseline

Baseline: `/Users/alex/sandbox/amaranth-v2/Tests/Data/Recordings/baseline-v0`

**G5 holds**: no breach.

Not checked in this run: set ami-clean, set ami-difficult, set librispeech, control music, control noise, control silence, boundary fixtures, notes checks

Transcripts not identical to the baseline (identity required: each is a breach): none

Corpus meetings flagged for review (not breaches; user decision 2026-10-22): none

