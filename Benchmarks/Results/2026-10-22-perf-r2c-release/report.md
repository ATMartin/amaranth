# Perf suite report

Generated 2026-10-22T12:53:24Z · commit `efe9b97` · Apple M2 Max · macOS 27.0.1 26A434
· worker build **release** · worker QoS userInitiated · Now drawing from 'AC Power'

Contains metrics and item IDs only (no transcript or notes text).

## Gates (M2 Max measured)

| # | Gate | Target (batch / incremental) | Measured | Status |
|---|---|---|---|---|
| G1 | Stop → final transcript with speakers, 60 min | ≤ 60 s / ≤ 20 s | 104 s per 60 min (worst ≥ 50-min meeting): timing-2src-60min/cold 105 s for 60 min; timing-2src-60min/warm 104 s for 60 min; corpus-working-session/default 63 s for 72 min | **not met** (batch) |
| G2 | Stop → notes, 60 min | ≤ 300 s | 250 s per 60 min: timing-2src-60min/cold 252 s; timing-2src-60min/warm 248 s; corpus-working-session/default 196 s | met |
| G3 | Batch path transcript, 60 min | ≤ 60 s | same as G1 (no incremental processing yet) | **not met** |
| G4 | Live text delay | median ≤ 2 s, p95 ≤ 4 s | not measured by perf-suite (T20) | – |
| G5 | Quality guard vs v0 | no breach | not compared (run with `--compare <baseline>`) | |
| G6 | Capture safety while processing during a call | zero loss | not exercised until T19 | – |
| G7 | Back-to-back meetings | meeting 1 ready while 2 records | not exercised until T19 | – |

## Items

Times in seconds. *exec* is the XPC round trip of each stage; *wait* is time queued behind other work. Stop → transcript and → notes are measured from enqueue (Stop) to commit.

| Item | Run | Audio min | Stop→transcript | Stop→notes | prepare | transcribe (wait) | diarize (wait) | reconcile | notes | Peak worker MiB | OK |
|---|---|---|---|---|---|---|---|---|---|---|---|
| timing-2src-60min | cold | 60.4 | 104.9 | 251.8 | 1.4 | 81.2 (0.8) | 20.0 (82.7) | 0.4 | 146.2 | 1333 | yes |
| timing-2src-60min | warm | 60.4 | 103.7 | 248.3 | 1.5 | 80.1 (0.8) | 20.0 (81.5) | 0.3 | 144.0 | 1505 | yes |
| ami-ES2004a-mix | default | 17.8 | 17.4 | – | 0.2 | 11.2 (0.3) | 5.6 (11.6) | 0.1 | – | 846 | yes |
| ami-IS1009a-mix | default | 14.3 | 15.5 | – | 0.2 | 10.5 (0.0) | 4.5 (10.6) | 0.0 | – | 827 | yes |
| ami-EN2002a-mix | default | 36.1 | 43.9 | – | 0.4 | 29.9 (0.8) | 12.6 (31.0) | 0.1 | – | 707 | yes |
| ami-ES2004a-array | default | 17.8 | 16.9 | – | 0.2 | 10.7 (0.5) | 5.6 (11.3) | 0.1 | – | 787 | yes |
| libri-mic | default | 3.5 | 2.3 | – | 0.0 | 2.2 (0.9) | 0.1 (3.1) | 0.0 | – | 497 | yes |
| control-silence | default | 1.3 | 0.6 | – | 0.0 | 0.2 (0.6) | 0.4 (0.8) | 0.0 | – | 611 | yes |
| control-noise | default | 1.3 | 2.3 | – | 0.0 | 1.9 (0.7) | 0.4 (2.5) | 0.0 | – | 569 | yes |
| control-music | default | 1.3 | 2.5 | – | 0.0 | 2.1 (0.3) | 0.4 (2.4) | 0.0 | – | 263 | yes |
| boundary-tts | default | 0.7 | 0.8 | – | 0.0 | 0.5 (0.0) | 0.3 (0.5) | 0.0 | – | 588 | yes |
| corpus-hangout-ai-session | default | 36.5 | 34.8 | 84.3 | 1.6 | 21.4 (0.9) | 10.9 (22.6) | 0.1 | 49.2 | 1373 | yes |
| corpus-hangout-ruby-session (held out) | default | 39.0 | 40.6 | 99.9 | 1.7 | 26.0 (0.3) | 11.8 (26.6) | 0.2 | 59.0 | 1325 | yes |
| corpus-working-session | default | 71.5 | 63.1 | 195.8 | 3.1 | 37.4 (0.6) | 21.2 (38.4) | 0.2 | 132.2 | 1527 | yes |
| corpus-youtopia-review-session | default | 22.5 | 21.4 | 69.1 | 1.0 | 12.9 (0.9) | 7.0 (14.0) | 0.1 | 47.5 | 1473 | yes |
| corpus-test-youtopia-recording | default | 2.1 | 3.5 | 15.6 | 0.1 | 2.1 (0.4) | 1.1 (2.6) | 0.0 | 12.1 | 1434 | yes |
| notes-planted-60min | default | 0.0 | – | 259.9 | – | – | – | – | 259.5 | 1439 | yes |
| notes-planted-120min | default | 0.0 | – | 535.5 | – | – | – | – | 534.7 | 1424 | yes |
| notes-inject-0 | default | 0.0 | – | 21.4 | – | – | – | – | 21.4 | 1424 | yes |
| notes-inject-1 | default | 0.0 | – | 20.6 | – | – | – | – | 20.6 | 1424 | yes |
| notes-inject-2 | default | 0.0 | – | 25.2 | – | – | – | – | 25.2 | 1424 | yes |
| notes-inject-3 | default | 0.0 | – | 29.7 | – | – | – | – | 29.7 | 1424 | yes |
| notes-inject-4 | default | 0.0 | – | 28.1 | – | – | – | – | 28.1 | 1424 | yes |
| notes-inject-5 | default | 0.0 | – | 23.2 | – | – | – | – | 23.1 | 1424 | yes |
| notes-inject-6 | default | 0.0 | – | 27.8 | – | – | – | – | 27.8 | 1424 | yes |
| notes-inject-7 | default | 0.0 | – | 28.5 | – | – | – | – | 28.5 | 1424 | yes |
| notes-inject-8 | default | 0.0 | – | 27.6 | – | – | – | – | 27.5 | 1424 | yes |
| notes-inject-9 | default | 0.0 | – | 28.2 | – | – | – | – | 28.2 | 1424 | yes |

## Where the time goes

Totals over 15 audio items (5.44 h of audio, first run each). Rates are seconds per hour of audio. Counters have no time.

### prepare

exec 10.0 s (1.8 s/h) = worker 10.0 s + IPC/launch 0.0 s; app-side input 0.3 s, commit 0.0 s.

| Interval | Seconds | s per audio hour | Share of worker time | Count |
|---|---|---|---|---|
| `prepare.total` | 9.92 | 1.8 | 98.8% | 15 |
| `prepare.readSegment` | 6.40 | 1.2 | 63.7% | 11674 |
| `prepare.downmix` | 1.67 | 0.3 | 16.6% | 11674 |
| `prepare.resample` | 1.23 | 0.2 | 12.2% | 11674 |
| `prepare.write` | 0.53 | 0.1 | 5.3% | 11691 |
| `stage.readInput` | 0.11 | 0.0 | 1.1% | 15 |
| `stage.writeOutput` | 0.00 | 0.0 | 0.0% | 15 |
| `prepare.segments` |  |  |  | 11674 |

### transcribe

exec 250.2 s (46.0 s/h) = worker 250.2 s + IPC/launch 0.0 s; app-side input 0.0 s, commit 2.2 s.

| Interval | Seconds | s per audio hour | Share of worker time | Count |
|---|---|---|---|---|
| `asr.decode.audioSeconds` (audio decoded, not time) | 35606 | 6545 | | |
| `asr.decode` | 225.98 | 41.5 | 90.3% | 2669 |
| `asr.decode.first` | 200.88 | 36.9 | 80.3% | 2357 |
| `asr.decode.retries` | 25.44 | 4.7 | 10.2% | 128 |
| `asr.plan` | 18.24 | 3.4 | 7.3% | 17 |
| `asr.vad.infer` | 18.05 | 3.3 | 7.2% | 50 |
| `model.load.asr` | 1.90 | 0.3 | 0.8% | 15 |
| `asr.checkpoint.write` | 1.77 | 0.3 | 0.7% | 2441 |
| `asr.window.read` | 0.64 | 0.1 | 0.3% | 5110 |
| `stage.writeOutput` | 0.59 | 0.1 | 0.2% | 15 |
| `asr.vad.read` | 0.16 | 0.0 | 0.1% | 50 |
| `asr.checkpoint.read` | 0.06 | 0.0 | 0.0% | 2441 |
| `asr.assemble` | 0.04 | 0.0 | 0.0% | 17 |
| `stage.readInput` | 0.00 | 0.0 | 0.0% | 15 |
| `asr.windows` |  |  |  | 2441 |
| `asr.windows.retried.garbled` |  |  |  | 1 |
| `asr.windows.retried.underYield` |  |  |  | 127 |
| `asr.windows.silent` |  |  |  | 84 |

### diarize

exec 102.1 s (18.8 s/h) = worker 102.0 s + IPC/launch 0.0 s; app-side input 0.0 s, commit 0.0 s.

| Interval | Seconds | s per audio hour | Share of worker time | Count |
|---|---|---|---|---|
| `diarize.engine` | 100.95 | 18.6 | 98.9% | 18 |
| `diarize.engine.embeddings` | 96.03 | 17.7 | 94.1% | 15 |
| `diarize.engine.segmentation` | 49.67 | 9.1 | 48.7% | 15 |
| `diarize.engine.clustering` | 2.57 | 0.5 | 2.5% | 15 |
| `model.load.diarization` | 0.91 | 0.2 | 0.9% | 15 |
| `diarize.engine.audioLoading` | 0.23 | 0.0 | 0.2% | 15 |
| `diarize.read` | 0.06 | 0.0 | 0.1% | 6 |
| `diarize.echo` | 0.03 | 0.0 | 0.0% | 2 |
| `stage.writeOutput` | 0.02 | 0.0 | 0.0% | 15 |
| `stage.readInput` | 0.00 | 0.0 | 0.0% | 15 |
| `diarize.engine.postProcessing` |  |  |  | 15 |

### reconcile

exec 1.3 s (0.2 s/h) = worker 1.3 s + IPC/launch 0.0 s; app-side input 1.6 s, commit 2.5 s.

| Interval | Seconds | s per audio hour | Share of worker time | Count |
|---|---|---|---|---|
| `stage.writeOutput` | 0.71 | 0.1 | 54.2% | 15 |
| `stage.readInput` | 0.51 | 0.1 | 39.2% | 15 |

### notes

exec 446.1 s (82.0 s/h) = worker 446.1 s + IPC/launch 0.0 s; app-side input 1.0 s, commit 1.0 s.

| Interval | Seconds | s per audio hour | Share of worker time | Count |
|---|---|---|---|---|
| `notes.extract` | 343.81 | 63.2 | 77.1% | 16 |
| `llm.generate` | 343.20 | 63.1 | 76.9% | 122 |
| `llm.prefill` | 99.30 | 18.3 | 22.3% | 122 |
| `notes.verify` | 79.08 | 14.5 | 17.7% | 100 |
| `notes.overview` | 19.97 | 3.7 | 4.5% | 6 |
| `llm.generate.sampling` | 3.64 | 0.7 | 0.8% | 122 |
| `model.load.notes` | 2.17 | 0.4 | 0.5% | 6 |
| `stage.readInput` | 0.45 | 0.1 | 0.1% | 6 |
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

