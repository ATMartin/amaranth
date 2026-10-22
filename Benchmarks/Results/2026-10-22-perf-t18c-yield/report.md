# Perf suite report

Generated 2026-10-22T22:29:24Z · commit `6d83f0a` · Apple M2 Max · macOS 27.0.1 26A434
· worker build **release** · worker QoS userInitiated · Now drawing from 'AC Power'

Contains metrics and item IDs only (no transcript or notes text).

## Gates (M2 Max measured)

| # | Gate | Target (batch / incremental) | Measured | Status |
|---|---|---|---|---|
| G1 | Stop → final transcript with speakers, 60 min | ≤ 60 s / ≤ 20 s | – s per 60 min (worst ≥ 50-min meeting): no meeting ≥ 50 min | – (batch) |
| G2 | Stop → notes, 60 min | ≤ 300 s | – s per 60 min: no meeting ≥ 50 min | – |
| G3 | Batch path transcript, 60 min | ≤ 60 s | same as G1 (no incremental processing yet) | – |
| G4 | Live text delay | median ≤ 2 s, p95 ≤ 4 s | not measured by perf-suite (T20) | – |
| G5 | Quality guard vs v0 | no breach | not compared (run with `--compare <baseline>`) | |
| G6 | Capture safety while processing during a call | zero loss | not exercised until T19 | – |
| G7 | Back-to-back meetings | meeting 1 ready while 2 records | not exercised until T19 | – |

## Items

Times in seconds. *exec* is the XPC round trip of each stage; *wait* is time queued behind other work. Stop → transcript and → notes are measured from enqueue (Stop) to commit.

| Item | Run | Audio min | Stop→transcript | Stop→notes | prepare | transcribe (wait) | diarize (wait) | reconcile | notes | Peak worker MiB | OK |
|---|---|---|---|---|---|---|---|---|---|---|---|
| yield-ami-IS1009a-during-notes | cold | 14.3 | 8.5 | – | 0.2 | 6.5 (0.6) | 7.8 (0.6) | 0.0 | – | 3778 | yes |

## Where the time goes

Totals over 1 audio items (0.24 h of audio, first run each). Rates are seconds per hour of audio. Counters have no time.

### prepare

exec 0.2 s (0.7 s/h) = worker 0.2 s + IPC/launch 0.0 s; app-side input 0.0 s, commit 0.0 s.

| Interval | Seconds | s per audio hour | Share of worker time | Count |
|---|---|---|---|---|
| `prepare.total` | 0.16 | 0.7 | 97.5% | 1 |
| `prepare.readSegment` | 0.14 | 0.6 | 84.3% | 431 |
| `prepare.write` | 0.02 | 0.1 | 11.2% | 432 |
| `stage.readInput` | 0.00 | 0.0 | 2.2% | 1 |
| `stage.writeOutput` | 0.00 | 0.0 | 0.2% | 1 |
| `prepare.downmix` | 0.00 | 0.0 | 0.1% | 431 |
| `prepare.resample` | 0.00 | 0.0 | 0.1% | 431 |
| `prepare.segments` |  |  |  | 431 |

### transcribe

exec 6.5 s (27.3 s/h) = worker 6.5 s + IPC/launch 0.0 s; app-side input 0.0 s, commit 0.1 s.

| Interval | Seconds | s per audio hour | Share of worker time | Count |
|---|---|---|---|---|
| `asr.decode.audioSeconds` (audio decoded, not time) | 1479 | 6191 | | |
| `asr.decode` | 11.04 | 46.2 | 169.5% | 109 |
| `asr.decode.first` | 8.99 | 37.6 | 138.1% | 85 |
| `asr.decode.retries` | 2.07 | 8.7 | 31.7% | 9 |
| `asr.vad.infer` | 0.71 | 3.0 | 10.9% | 2 |
| `asr.plan` | 0.49 | 2.1 | 7.6% | 1 |
| `model.load.asr` | 0.32 | 1.3 | 4.8% | 1 |
| `asr.checkpoint.write` | 0.06 | 0.3 | 0.9% | 87 |
| `asr.window.read` | 0.03 | 0.1 | 0.5% | 196 |
| `stage.writeOutput` | 0.02 | 0.1 | 0.3% | 1 |
| `asr.vad.read` | 0.01 | 0.0 | 0.1% | 2 |
| `asr.checkpoint.read` | 0.00 | 0.0 | 0.0% | 87 |
| `asr.assemble` | 0.00 | 0.0 | 0.0% | 1 |
| `stage.readInput` | 0.00 | 0.0 | 0.0% | 1 |
| `asr.windows` |  |  |  | 87 |
| `asr.windows.retried.underYield` |  |  |  | 9 |
| `asr.windows.silent` |  |  |  | 2 |

### diarize

exec 7.8 s (32.7 s/h) = worker 7.8 s + IPC/launch 0.0 s; app-side input 0.0 s, commit 0.0 s.

| Interval | Seconds | s per audio hour | Share of worker time | Count |
|---|---|---|---|---|
| `diarize.engine` | 7.34 | 30.7 | 94.1% | 1 |
| `diarize.engine.embeddings` | 7.21 | 30.2 | 92.5% | 1 |
| `diarize.engine.segmentation` | 2.52 | 10.5 | 32.2% | 1 |
| `model.load.diarization` | 0.08 | 0.3 | 1.1% | 1 |
| `diarize.engine.clustering` | 0.05 | 0.2 | 0.6% | 1 |
| `diarize.engine.audioLoading` | 0.02 | 0.1 | 0.3% | 1 |
| `stage.writeOutput` | 0.00 | 0.0 | 0.0% | 1 |
| `stage.readInput` | 0.00 | 0.0 | 0.0% | 1 |
| `diarize.engine.postProcessing` |  |  |  | 1 |

### reconcile

exec 0.0 s (0.2 s/h) = worker 0.0 s + IPC/launch 0.0 s; app-side input 0.1 s, commit 0.1 s.

| Interval | Seconds | s per audio hour | Share of worker time | Count |
|---|---|---|---|---|
| `stage.writeOutput` | 0.02 | 0.1 | 55.0% | 1 |
| `stage.readInput` | 0.02 | 0.1 | 38.4% | 1 |

### notes

exec 0.0 s (0.0 s/h) = worker 0.0 s + IPC/launch 0.0 s; app-side input 0.0 s, commit 0.0 s.

| Interval | Seconds | s per audio hour | Share of worker time | Count |
|---|---|---|---|---|

## Quality (first run of each item)

| Set | WER | DER | labelled | correct | failed coverage s |
|---|---|---|---|---|---|

Controls (words; must be 0): 

Boundary fixture: not run

