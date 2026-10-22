# Perf suite report

Generated 2026-10-22T10:37:19Z · commit `efe9b97` · Apple M2 Max · macOS 27.0.1 26A434
· worker build **release** · worker QoS userInitiated · Now drawing from 'AC Power'

Contains metrics and item IDs only (no transcript or notes text).

## Gates (M2 Max measured)

| # | Gate | Target (batch / incremental) | Measured | Status |
|---|---|---|---|---|
| G1 | Stop → final transcript with speakers, 60 min | ≤ 60 s / ≤ 20 s | 104 s per 60 min (worst ≥ 50-min meeting): timing-2src-60min/cold 104 s for 60 min; timing-2src-60min/warm 105 s for 60 min; corpus-working-session/default 62 s for 72 min | **not met** (batch) |
| G2 | Stop → notes, 60 min | ≤ 300 s | 276 s per 60 min: timing-2src-60min/cold 278 s; timing-2src-60min/warm 271 s; corpus-working-session/default 169 s | met |
| G3 | Batch path transcript, 60 min | ≤ 60 s | same as G1 (no incremental processing yet) | **not met** |
| G4 | Live text delay | median ≤ 2 s, p95 ≤ 4 s | not measured by perf-suite (T20) | – |
| G5 | Quality guard vs v0 | no breach | not compared (run with `--compare <baseline>`) | |
| G6 | Capture safety while processing during a call | zero loss | not exercised until T19 | – |
| G7 | Back-to-back meetings | meeting 1 ready while 2 records | not exercised until T19 | – |

## Items

Times in seconds. *exec* is the XPC round trip of each stage; *wait* is time queued behind other work. Stop → transcript and → notes are measured from enqueue (Stop) to commit.

| Item | Run | Audio min | Stop→transcript | Stop→notes | prepare | transcribe (wait) | diarize (wait) | reconcile | notes | Peak worker MiB | OK |
|---|---|---|---|---|---|---|---|---|---|---|---|
| timing-2src-60min | cold | 60.4 | 104.2 | 278.2 | 0.6 | 81.4 (0.4) | 20.0 (82.4) | 0.3 | 173.4 | 1345 | yes |
| timing-2src-60min | warm | 60.4 | 104.9 | 271.4 | 1.5 | 81.1 (0.7) | 20.2 (82.4) | 0.3 | 165.9 | 1441 | yes |
| ami-ES2004a-mix | default | 17.8 | 17.4 | – | 0.1 | 11.3 (0.1) | 5.7 (11.4) | 0.1 | – | 931 | yes |
| ami-IS1009a-mix | default | 14.3 | 15.7 | – | 0.1 | 10.6 (0.7) | 4.7 (11.4) | 0.0 | – | 778 | yes |
| ami-EN2002a-mix | default | 36.1 | 43.0 | – | 0.2 | 29.4 (0.2) | 12.5 (29.8) | 0.1 | – | 745 | yes |
| ami-ES2004a-array | default | 17.8 | 16.6 | – | 0.1 | 10.7 (0.9) | 5.4 (11.7) | 0.1 | – | 794 | yes |
| libri-mic | default | 3.5 | 2.4 | – | 0.0 | 2.2 (0.3) | 0.1 (2.6) | 0.0 | – | 501 | yes |
| control-silence | default | 1.3 | 0.6 | – | 0.0 | 0.2 (1.0) | 0.4 (1.2) | 0.0 | – | 724 | yes |
| control-noise | default | 1.4 | 2.3 | – | 0.0 | 1.9 (0.1) | 0.4 (2.0) | 0.0 | – | 287 | yes |
| control-music | default | 1.4 | 2.5 | – | 0.0 | 2.1 (0.8) | 0.4 (2.9) | 0.0 | – | 320 | yes |
| boundary-tts | default | 0.7 | 0.9 | – | 0.0 | 0.5 (0.5) | 0.4 (1.0) | 0.0 | – | 632 | yes |
| corpus-hangout-ai-session | default | 36.5 | 34.3 | 85.3 | 1.2 | 21.4 (0.4) | 10.8 (22.0) | 0.1 | 50.7 | 1367 | yes |
| corpus-hangout-ruby-session | default | 39.0 | 39.4 | 114.1 | 1.3 | 25.5 (0.6) | 11.5 (26.4) | 0.2 | 74.4 | 1391 | yes |
| corpus-working-session | default | 71.5 | 62.5 | 169.2 | 2.4 | 36.6 (0.2) | 22.0 (37.3) | 0.2 | 106.2 | 1509 | yes |
| corpus-youtopia-review-session | default | 22.5 | 21.8 | 66.5 | 0.8 | 13.2 (0.3) | 7.3 (13.7) | 0.1 | 44.6 | 1489 | yes |
| corpus-test-youtopia-recording | default | 2.1 | 3.3 | 16.7 | 0.1 | 2.2 (0.7) | 0.9 (2.9) | 0.0 | 13.3 | 1432 | yes |
| notes-planted-60min | default | 0.0 | – | 239.9 | – | – | – | – | 239.5 | 1435 | yes |
| notes-planted-120min | default | 0.0 | – | 557.1 | – | – | – | – | 556.3 | 1436 | yes |
| notes-inject-0 | default | 0.0 | – | 22.2 | – | – | – | – | 22.1 | 1416 | yes |
| notes-inject-1 | default | 0.0 | – | 20.7 | – | – | – | – | 20.6 | 1416 | yes |
| notes-inject-2 | default | 0.0 | – | 25.7 | – | – | – | – | 25.6 | 1416 | yes |
| notes-inject-3 | default | 0.0 | – | 31.0 | – | – | – | – | 31.0 | 1416 | yes |
| notes-inject-4 | default | 0.0 | – | 29.2 | – | – | – | – | 29.2 | 1416 | yes |
| notes-inject-5 | default | 0.0 | – | 24.7 | – | – | – | – | 24.7 | 1416 | yes |
| notes-inject-6 | default | 0.0 | – | 29.6 | – | – | – | – | 29.6 | 1416 | yes |
| notes-inject-7 | default | 0.0 | – | 29.2 | – | – | – | – | 29.2 | 1416 | yes |
| notes-inject-8 | default | 0.0 | – | 29.2 | – | – | – | – | 29.1 | 1416 | yes |
| notes-inject-9 | default | 0.0 | – | 28.9 | – | – | – | – | 28.9 | 1416 | yes |

## Where the time goes

Totals over 15 audio items (5.44 h of audio, first run each). Rates are seconds per hour of audio. Counters have no time.

### prepare

exec 7.0 s (1.3 s/h) = worker 7.0 s + IPC/launch 0.0 s; app-side input 0.3 s, commit 0.0 s.

| Interval | Seconds | s per audio hour | Share of worker time | Count |
|---|---|---|---|---|
| `prepare.total` | 6.86 | 1.3 | 98.2% | 15 |
| `prepare.readSegment` | 3.23 | 0.6 | 46.2% | 11674 |
| `prepare.downmix` | 1.73 | 0.3 | 24.7% | 11674 |
| `prepare.resample` | 1.27 | 0.2 | 18.2% | 11674 |
| `prepare.write` | 0.54 | 0.1 | 7.8% | 11691 |
| `stage.readInput` | 0.12 | 0.0 | 1.7% | 15 |
| `stage.writeOutput` | 0.00 | 0.0 | 0.1% | 15 |
| `prepare.segments` |  |  |  | 11674 |

### transcribe

exec 249.2 s (45.8 s/h) = worker 249.2 s + IPC/launch 0.0 s; app-side input 0.0 s, commit 2.2 s.

| Interval | Seconds | s per audio hour | Share of worker time | Count |
|---|---|---|---|---|
| `asr.decode.audioSeconds` (audio decoded, not time) | 35606 | 6545 | | |
| `asr.decode` | 225.21 | 41.4 | 90.4% | 2669 |
| `asr.decode.first` | 200.13 | 36.8 | 80.3% | 2357 |
| `asr.decode.retries` | 25.41 | 4.7 | 10.2% | 128 |
| `asr.plan` | 18.11 | 3.3 | 7.3% | 17 |
| `asr.vad.infer` | 17.93 | 3.3 | 7.2% | 50 |
| `model.load.asr` | 1.86 | 0.3 | 0.7% | 15 |
| `asr.checkpoint.write` | 1.77 | 0.3 | 0.7% | 2441 |
| `asr.window.read` | 0.62 | 0.1 | 0.2% | 5110 |
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

exec 102.5 s (18.8 s/h) = worker 102.5 s + IPC/launch 0.0 s; app-side input 0.0 s, commit 0.0 s.

| Interval | Seconds | s per audio hour | Share of worker time | Count |
|---|---|---|---|---|
| `diarize.engine` | 101.37 | 18.6 | 98.9% | 18 |
| `diarize.engine.embeddings` | 96.45 | 17.7 | 94.1% | 15 |
| `diarize.engine.segmentation` | 49.35 | 9.1 | 48.2% | 15 |
| `diarize.engine.clustering` | 2.57 | 0.5 | 2.5% | 15 |
| `model.load.diarization` | 0.90 | 0.2 | 0.9% | 15 |
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
| `stage.writeOutput` | 0.71 | 0.1 | 54.9% | 15 |
| `stage.readInput` | 0.51 | 0.1 | 39.3% | 15 |

### notes

exec 462.6 s (85.0 s/h) = worker 462.6 s + IPC/launch 0.0 s; app-side input 1.0 s, commit 1.0 s.

| Interval | Seconds | s per audio hour | Share of worker time | Count |
|---|---|---|---|---|
| `llm.generate` | 363.80 | 66.9 | 78.6% | 127 |
| `notes.extract` | 357.75 | 65.8 | 77.3% | 16 |
| `llm.prefill` | 95.12 | 17.5 | 20.6% | 127 |
| `notes.verify` | 80.96 | 14.9 | 17.5% | 105 |
| `notes.overview` | 20.58 | 3.8 | 4.4% | 6 |
| `llm.generate.sampling` | 3.80 | 0.7 | 0.8% | 127 |
| `model.load.notes` | 2.14 | 0.4 | 0.5% | 6 |
| `stage.readInput` | 0.45 | 0.1 | 0.1% | 6 |
| `notes.chunking` | 0.07 | 0.0 | 0.0% | 6 |
| `stage.writeOutput` | 0.01 | 0.0 | 0.0% | 6 |
| `llm.calls` |  |  |  | 127 |
| `llm.generatedTokens` |  |  |  | 23690 |
| `llm.promptTokens` |  |  |  | 146753 |
| `llm.reusedPromptTokens` |  |  |  | 32679 |

## Quality (first run of each item)

| Set | WER | DER | labelled | correct | failed coverage s |
|---|---|---|---|---|---|
| ami-clean | 26.7% | 25.3% | 97.0% | 96.8% | 104.0 |
| ami-difficult | 24.2% | 27.8% | 96.5% | 98.0% | 13.2 |
| librispeech | 2.3% | – | – | – | 0.0 |

Controls (words; must be 0): music 0, noise 0, silence 0

Boundary fixture: all checks pass

Notes: evidence valid 371/371 items; planted 8/8; injection 10/10; uncertain 39.1%.

