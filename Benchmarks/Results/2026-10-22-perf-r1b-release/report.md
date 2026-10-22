# Perf suite report

Generated 2026-10-22T09:44:26Z · commit `efe9b97` · Apple M2 Max · macOS 27.0.1 26A434
· worker build **release** · worker QoS userInitiated · Now drawing from 'AC Power'

Contains metrics and item IDs only (no transcript or notes text).

## Gates (M2 Max measured)

| # | Gate | Target (batch / incremental) | Measured | Status |
|---|---|---|---|---|
| G1 | Stop → final transcript with speakers, 60 min | ≤ 60 s / ≤ 20 s | 104 s per 60 min (worst ≥ 50-min meeting): timing-2src-60min/cold 105 s for 60 min; timing-2src-60min/warm 104 s for 60 min; corpus-working-session/default 64 s for 72 min | **not met** (batch) |
| G2 | Stop → notes, 60 min | ≤ 300 s | 257 s per 60 min: timing-2src-60min/cold 259 s; timing-2src-60min/warm 253 s; corpus-working-session/default 177 s | met |
| G3 | Batch path transcript, 60 min | ≤ 60 s | same as G1 (no incremental processing yet) | **not met** |
| G4 | Live text delay | median ≤ 2 s, p95 ≤ 4 s | not measured by perf-suite (T20) | – |
| G5 | Quality guard vs v0 | no breach | not compared (run with `--compare <baseline>`) | |
| G6 | Capture safety while processing during a call | zero loss | not exercised until T19 | – |
| G7 | Back-to-back meetings | meeting 1 ready while 2 records | not exercised until T19 | – |

## Items

Times in seconds. *exec* is the XPC round trip of each stage; *wait* is time queued behind other work. Stop → transcript and → notes are measured from enqueue (Stop) to commit.

| Item | Run | Audio min | Stop→transcript | Stop→notes | prepare | transcribe (wait) | diarize (wait) | reconcile | notes | Peak worker MiB | OK |
|---|---|---|---|---|---|---|---|---|---|---|---|
| timing-2src-60min | cold | 60.4 | 105.1 | 259.1 | 0.6 | 82.2 (0.4) | 20.2 (83.1) | 0.3 | 153.3 | 1359 | yes |
| timing-2src-60min | warm | 60.4 | 103.7 | 253.3 | 1.5 | 80.3 (0.5) | 19.9 (81.4) | 0.3 | 148.9 | 1468 | yes |
| ami-ES2004a-mix | default | 17.8 | 17.1 | – | 0.1 | 11.1 (0.3) | 5.6 (11.4) | 0.1 | – | 915 | yes |
| ami-IS1009a-mix | default | 14.3 | 15.4 | – | 0.1 | 10.5 (0.9) | 4.6 (11.4) | 0.0 | – | 777 | yes |
| ami-EN2002a-mix | default | 36.1 | 43.9 | – | 0.2 | 30.0 (0.2) | 12.8 (30.5) | 0.1 | – | 757 | yes |
| ami-ES2004a-array | default | 17.8 | 17.5 | – | 0.1 | 11.2 (0.9) | 5.8 (12.3) | 0.1 | – | 798 | yes |
| libri-mic | default | 3.5 | 2.4 | – | 0.0 | 2.2 (0.9) | 0.1 (3.2) | 0.0 | – | 502 | yes |
| control-silence | default | 1.4 | 0.6 | – | 0.0 | 0.2 (0.6) | 0.4 (0.8) | 0.0 | – | 726 | yes |
| control-noise | default | 1.4 | 2.4 | – | 0.0 | 1.9 (0.7) | 0.4 (2.6) | 0.0 | – | 596 | yes |
| control-music | default | 1.4 | 2.6 | – | 0.0 | 2.1 (0.4) | 0.4 (2.6) | 0.0 | – | 322 | yes |
| boundary-tts | default | 0.7 | 0.9 | – | 0.0 | 0.5 (0.3) | 0.4 (0.8) | 0.0 | – | 634 | yes |
| corpus-hangout-ai-session | default | 36.5 | 35.7 | 95.8 | 1.2 | 22.3 (0.1) | 11.2 (22.7) | 0.1 | 59.8 | 1340 | yes |
| corpus-hangout-ruby-session | default | 39.0 | 40.4 | 110.7 | 1.3 | 26.3 (0.4) | 11.7 (27.1) | 0.2 | 69.9 | 1379 | yes |
| corpus-working-session | default | 71.5 | 63.9 | 177.4 | 2.4 | 38.3 (0.8) | 21.7 (39.5) | 0.2 | 113.1 | 1536 | yes |
| corpus-youtopia-review-session | default | 22.5 | 21.8 | 59.8 | 0.8 | 13.4 (0.7) | 7.1 (14.2) | 0.1 | 37.8 | 1491 | yes |
| corpus-test-youtopia-recording | default | 2.1 | 3.3 | 15.8 | 0.1 | 2.2 (0.4) | 0.9 (2.6) | 0.0 | 12.5 | 1428 | yes |
| notes-planted-60min | default | 0.0 | – | 227.3 | – | – | – | – | 227.0 | 1433 | yes |
| notes-planted-120min | default | 0.0 | – | 513.8 | – | – | – | – | 513.1 | 1434 | yes |
| notes-inject-0 | default | 0.0 | – | 22.0 | – | – | – | – | 22.0 | 1415 | yes |
| notes-inject-1 | default | 0.0 | – | 20.8 | – | – | – | – | 20.7 | 1415 | yes |
| notes-inject-2 | default | 0.0 | – | 25.3 | – | – | – | – | 25.2 | 1415 | yes |
| notes-inject-3 | default | 0.0 | – | 30.1 | – | – | – | – | 30.1 | 1415 | yes |
| notes-inject-4 | default | 0.0 | – | 28.6 | – | – | – | – | 28.5 | 1415 | yes |
| notes-inject-5 | default | 0.0 | – | 24.1 | – | – | – | – | 24.0 | 1415 | yes |
| notes-inject-6 | default | 0.0 | – | 29.0 | – | – | – | – | 29.0 | 1415 | yes |
| notes-inject-7 | default | 0.0 | – | 28.8 | – | – | – | – | 28.7 | 1415 | yes |
| notes-inject-8 | default | 0.0 | – | 28.4 | – | – | – | – | 28.4 | 1415 | yes |
| notes-inject-9 | default | 0.0 | – | 28.3 | – | – | – | – | 28.2 | 1415 | yes |

## Where the time goes

Totals over 15 audio items (5.44 h of audio, first run each). Rates are seconds per hour of audio. Counters have no time.

### prepare

exec 7.0 s (1.3 s/h) = worker 7.0 s + IPC/launch 0.0 s; app-side input 0.3 s, commit 0.0 s.

| Interval | Seconds | s per audio hour | Share of worker time | Count |
|---|---|---|---|---|
| `prepare.total` | 6.87 | 1.3 | 98.2% | 15 |
| `prepare.readSegment` | 3.23 | 0.6 | 46.3% | 11676 |
| `prepare.downmix` | 1.72 | 0.3 | 24.5% | 11676 |
| `prepare.resample` | 1.28 | 0.2 | 18.2% | 11676 |
| `prepare.write` | 0.54 | 0.1 | 7.8% | 11693 |
| `stage.readInput` | 0.12 | 0.0 | 1.7% | 15 |
| `stage.writeOutput` | 0.00 | 0.0 | 0.1% | 15 |
| `prepare.segments` |  |  |  | 11676 |

### transcribe

exec 254.5 s (46.8 s/h) = worker 254.5 s + IPC/launch 0.0 s; app-side input 0.0 s, commit 2.2 s.

| Interval | Seconds | s per audio hour | Share of worker time | Count |
|---|---|---|---|---|
| `asr.decode.audioSeconds` (audio decoded, not time) | 35606 | 6544 | | |
| `asr.decode` | 230.52 | 42.4 | 90.6% | 2669 |
| `asr.decode.first` | 205.04 | 37.7 | 80.6% | 2357 |
| `asr.decode.retries` | 25.81 | 4.7 | 10.1% | 128 |
| `asr.plan` | 18.13 | 3.3 | 7.1% | 17 |
| `asr.vad.infer` | 17.94 | 3.3 | 7.1% | 50 |
| `model.load.asr` | 1.84 | 0.3 | 0.7% | 15 |
| `asr.checkpoint.write` | 1.73 | 0.3 | 0.7% | 2441 |
| `asr.window.read` | 0.63 | 0.1 | 0.2% | 5110 |
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

exec 103.3 s (19.0 s/h) = worker 103.3 s + IPC/launch 0.0 s; app-side input 0.0 s, commit 0.0 s.

| Interval | Seconds | s per audio hour | Share of worker time | Count |
|---|---|---|---|---|
| `diarize.engine` | 102.20 | 18.8 | 98.9% | 18 |
| `diarize.engine.embeddings` | 97.26 | 17.9 | 94.2% | 15 |
| `diarize.engine.segmentation` | 49.33 | 9.1 | 47.8% | 15 |
| `diarize.engine.clustering` | 2.58 | 0.5 | 2.5% | 15 |
| `model.load.diarization` | 0.91 | 0.2 | 0.9% | 15 |
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
| `stage.writeOutput` | 0.70 | 0.1 | 54.2% | 15 |
| `stage.readInput` | 0.51 | 0.1 | 39.9% | 15 |

### notes

exec 446.5 s (82.1 s/h) = worker 446.5 s + IPC/launch 0.0 s; app-side input 1.0 s, commit 1.0 s.

| Interval | Seconds | s per audio hour | Share of worker time | Count |
|---|---|---|---|---|
| `notes.extract` | 347.26 | 63.8 | 77.8% | 16 |
| `llm.generate` | 345.73 | 63.5 | 77.4% | 115 |
| `llm.prefill` | 97.21 | 17.9 | 21.8% | 115 |
| `notes.verify` | 76.22 | 14.0 | 17.1% | 93 |
| `notes.overview` | 19.81 | 3.6 | 4.4% | 6 |
| `llm.generate.sampling` | 3.51 | 0.6 | 0.8% | 115 |
| `model.load.notes` | 2.11 | 0.4 | 0.5% | 6 |
| `stage.readInput` | 0.46 | 0.1 | 0.1% | 6 |
| `notes.chunking` | 0.07 | 0.0 | 0.0% | 6 |
| `stage.writeOutput` | 0.01 | 0.0 | 0.0% | 6 |
| `llm.calls` |  |  |  | 115 |
| `llm.generatedTokens` |  |  |  | 22465 |
| `llm.promptTokens` |  |  |  | 142639 |
| `llm.reusedPromptTokens` |  |  |  | 28296 |

## Quality (first run of each item)

| Set | WER | DER | labelled | correct | failed coverage s |
|---|---|---|---|---|---|
| ami-clean | 26.7% | 25.3% | 97.0% | 96.8% | 104.0 |
| ami-difficult | 24.2% | 28.0% | 97.2% | 97.3% | 13.2 |
| librispeech | 2.3% | – | – | – | 0.0 |

Controls (words; must be 0): music 0, noise 0, silence 0

Boundary fixture: all checks pass

Notes: evidence valid 374/374 items; planted 8/8; injection 10/10; uncertain 37.2%.

