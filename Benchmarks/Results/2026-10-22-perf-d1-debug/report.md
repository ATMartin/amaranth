# Perf suite report

Generated 2026-10-22T08:39:19Z · commit `efe9b97` · Apple M2 Max · macOS 27.0.1 26A434
· worker build **debug** · worker QoS userInitiated · Now drawing from 'AC Power'

Contains metrics and item IDs only (no transcript or notes text).

## Gates (M2 Max measured)

| # | Gate | Target (batch / incremental) | Measured | Status |
|---|---|---|---|---|
| G1 | Stop → final transcript with speakers, 60 min | ≤ 60 s / ≤ 20 s | worst 389 s per audio hour; ≥ 50 min: corpus-working-session/default 326 s (72 min); corpus-working-session/warm 330 s (72 min) | **not met** (batch) |
| G2 | Stop → notes, 60 min | ≤ 300 s | worst 1134 s per audio hour; ≥ 50 min: corpus-working-session/default 508 s; corpus-working-session/warm 523 s | **not met** |
| G3 | Batch path transcript, 60 min | ≤ 60 s | same as G1 (no incremental processing yet) | **not met** |
| G4 | Live text delay | median ≤ 2 s, p95 ≤ 4 s | not measured by perf-suite (T20) | – |
| G5 | Quality guard vs v0 | no breach | not compared (run with `--compare <baseline>`) | |
| G6 | Capture safety while processing during a call | zero loss | not exercised until T19 | – |
| G7 | Back-to-back meetings | meeting 1 ready while 2 records | not exercised until T19 | – |

## Items

Times in seconds. *exec* is the XPC round trip of each stage; *wait* is time queued behind other work. Stop → transcript and → notes are measured from enqueue (Stop) to commit.

| Item | Run | Audio min | Stop→transcript | Stop→notes | prepare | transcribe (wait) | diarize (wait) | reconcile | notes | Peak worker MiB | OK |
|---|---|---|---|---|---|---|---|---|---|---|---|
| ami-ES2004a-mix | cold | 17.8 | 48.2 | – | 5.1 | 25.5 (0.5) | 17.1 (26.1) | 0.1 | – | 809 | yes |
| ami-IS1009a-mix | default | 14.3 | 40.4 | – | 3.9 | 22.5 (0.1) | 13.7 (22.7) | 0.1 | – | 753 | yes |
| ami-EN2002a-mix | default | 36.1 | 112.1 | – | 9.7 | 63.9 (0.9) | 37.2 (65.1) | 0.4 | – | 715 | yes |
| ami-ES2004a-array | default | 17.8 | 47.4 | – | 4.8 | 25.0 (0.3) | 17.2 (25.3) | 0.1 | – | 734 | yes |
| libri-mic | default | 3.5 | 6.0 | – | 0.9 | 4.9 (0.6) | 0.1 (5.5) | 0.0 | – | 464 | yes |
| control-silence | default | 1.3 | 2.3 | – | 0.4 | 0.7 (0.2) | 1.2 (0.9) | 0.0 | – | 254 | yes |
| control-noise | default | 1.4 | 4.5 | – | 0.4 | 2.8 (0.9) | 1.3 (3.7) | 0.0 | – | 554 | yes |
| control-music | default | 1.3 | 4.7 | – | 0.4 | 3.0 (0.5) | 1.3 (3.5) | 0.0 | – | 670 | yes |
| boundary-tts | default | 0.8 | 2.1 | – | 0.2 | 0.9 (0.8) | 0.9 (1.7) | 0.0 | – | 483 | yes |
| corpus-hangout-ai-session | default | 36.5 | 166.4 | 262.1 | 81.2 | 49.7 (1.0) | 34.5 (50.9) | 0.3 | 95.4 | 1351 | yes |
| corpus-hangout-ruby-session | default | 39.0 | 180.0 | 307.2 | 88.7 | 53.5 (0.0) | 36.5 (53.8) | 0.4 | 126.8 | 1325 | yes |
| corpus-working-session | default | 71.5 | 326.1 | 508.0 | 163.1 | 84.6 (0.4) | 76.4 (85.4) | 0.7 | 181.3 | 1470 | yes |
| corpus-working-session | warm | 71.5 | 330.1 | 522.6 | 164.9 | 85.9 (0.7) | 77.3 (87.1) | 0.7 | 192.0 | 1426 | yes |
| corpus-youtopia-review-session | default | 22.5 | 102.4 | 178.0 | 51.3 | 29.1 (0.9) | 21.3 (30.1) | 0.2 | 75.4 | 1308 | yes |
| corpus-test-youtopia-recording | default | 2.1 | 13.8 | 40.2 | 5.6 | 5.0 (0.8) | 3.1 (5.8) | 0.0 | 26.4 | 1314 | yes |
| notes-planted-60min | default | 0.0 | – | 388.8 | – | – | – | – | 388.3 | 1323 | yes |
| notes-planted-120min | default | 0.0 | – | 814.4 | – | – | – | – | 813.4 | 1321 | yes |
| notes-inject-0 | default | 0.0 | – | 36.0 | – | – | – | – | 36.0 | 1321 | yes |
| notes-inject-1 | default | 0.0 | – | 34.0 | – | – | – | – | 33.9 | 1321 | yes |
| notes-inject-2 | default | 0.0 | – | 41.1 | – | – | – | – | 41.0 | 1321 | yes |
| notes-inject-3 | default | 0.0 | – | 49.6 | – | – | – | – | 49.6 | 1321 | yes |
| notes-inject-4 | default | 0.0 | – | 46.2 | – | – | – | – | 46.1 | 1321 | yes |
| notes-inject-5 | default | 0.0 | – | 39.6 | – | – | – | – | 39.6 | 1321 | yes |
| notes-inject-6 | default | 0.0 | – | 48.0 | – | – | – | – | 48.0 | 1321 | yes |
| notes-inject-7 | default | 0.0 | – | 47.3 | – | – | – | – | 47.3 | 1321 | yes |
| notes-inject-8 | default | 0.0 | – | 47.5 | – | – | – | – | 47.5 | 1321 | yes |
| notes-inject-9 | default | 0.0 | – | 46.3 | – | – | – | – | 46.3 | 1321 | yes |

## Where the time goes

Totals over 14 audio items (4.43 h of audio, first run each). Rates are seconds per hour of audio. Counters have no time.

### prepare

exec 415.9 s (93.8 s/h) = worker 415.8 s + IPC/launch 0.0 s; app-side input 0.2 s, commit 0.0 s.

| Interval | Seconds | s per audio hour | Share of worker time | Count |
|---|---|---|---|---|
| `prepare.total` | 415.75 | 93.8 | 100.0% | 14 |
| `prepare.downmix` | 241.63 | 54.5 | 58.1% | 8048 |
| `prepare.readSegment` | 129.51 | 29.2 | 31.1% | 8048 |
| `prepare.write` | 42.53 | 9.6 | 10.2% | 8063 |
| `prepare.resample` | 1.34 | 0.3 | 0.3% | 8048 |
| `stage.readInput` | 0.09 | 0.0 | 0.0% | 14 |
| `stage.writeOutput` | 0.00 | 0.0 | 0.0% | 14 |
| `prepare.segments` |  |  |  | 8048 |

### transcribe

exec 371.0 s (83.7 s/h) = worker 371.0 s + IPC/launch 0.0 s; app-side input 0.0 s, commit 1.7 s.

| Interval | Seconds | s per audio hour | Share of worker time | Count |
|---|---|---|---|---|
| `asr.decode.audioSeconds` (audio decoded, not time) | 23746 | 5356 | | |
| `asr.decode.first` | 233.99 | 52.8 | 63.1% | 1570 |
| `asr.decode` | 204.65 | 46.2 | 55.2% | 1756 |
| `asr.window.read` | 92.25 | 20.8 | 24.9% | 3405 |
| `asr.plan` | 52.06 | 11.7 | 14.0% | 15 |
| `asr.vad.read` | 39.31 | 8.9 | 10.6% | 36 |
| `asr.decode.retries` | 25.76 | 5.8 | 6.9% | 76 |
| `asr.vad.infer` | 12.69 | 2.9 | 3.4% | 36 |
| `model.load.asr` | 1.93 | 0.4 | 0.5% | 14 |
| `asr.checkpoint.write` | 1.22 | 0.3 | 0.3% | 1649 |
| `stage.writeOutput` | 0.43 | 0.1 | 0.1% | 14 |
| `asr.assemble` | 0.11 | 0.0 | 0.0% | 15 |
| `asr.checkpoint.read` | 0.04 | 0.0 | 0.0% | 1649 |
| `stage.readInput` | 0.00 | 0.0 | 0.0% | 14 |
| `asr.windows` |  |  |  | 1649 |
| `asr.windows.retried.underYield` |  |  |  | 76 |
| `asr.windows.silent` |  |  |  | 79 |

### diarize

exec 261.9 s (59.1 s/h) = worker 261.9 s + IPC/launch 0.0 s; app-side input 0.0 s, commit 0.0 s.

| Interval | Seconds | s per audio hour | Share of worker time | Count |
|---|---|---|---|---|
| `diarize.engine` | 250.09 | 56.4 | 95.5% | 15 |
| `diarize.engine.embeddings` | 228.24 | 51.5 | 87.2% | 12 |
| `diarize.engine.segmentation` | 62.30 | 14.1 | 23.8% | 12 |
| `diarize.read` | 10.01 | 2.3 | 3.8% | 3 |
| `diarize.engine.clustering` | 7.81 | 1.8 | 3.0% | 12 |
| `model.load.diarization` | 0.85 | 0.2 | 0.3% | 14 |
| `diarize.echo` | 0.79 | 0.2 | 0.3% | 1 |
| `diarize.engine.audioLoading` | 0.23 | 0.1 | 0.1% | 12 |
| `stage.writeOutput` | 0.02 | 0.0 | 0.0% | 14 |
| `stage.readInput` | 0.00 | 0.0 | 0.0% | 14 |
| `diarize.engine.postProcessing` |  |  |  | 12 |

### reconcile

exec 2.3 s (0.5 s/h) = worker 2.3 s + IPC/launch 0.0 s; app-side input 1.2 s, commit 1.9 s.

| Interval | Seconds | s per audio hour | Share of worker time | Count |
|---|---|---|---|---|
| `stage.writeOutput` | 0.53 | 0.1 | 23.1% | 14 |
| `stage.readInput` | 0.40 | 0.1 | 17.3% | 14 |

### notes

exec 505.3 s (114.0 s/h) = worker 505.3 s + IPC/launch 0.0 s; app-side input 0.7 s, commit 0.7 s.

| Interval | Seconds | s per audio hour | Share of worker time | Count |
|---|---|---|---|---|
| `llm.generate` | 439.64 | 99.2 | 87.0% | 77 |
| `notes.extract` | 388.94 | 87.7 | 77.0% | 10 |
| `llm.generate.sampling` | 223.30 | 50.4 | 44.2% | 77 |
| `notes.verify` | 76.51 | 17.3 | 15.1% | 62 |
| `llm.prefill` | 58.81 | 13.3 | 11.6% | 77 |
| `notes.overview` | 33.26 | 7.5 | 6.6% | 5 |
| `model.load.notes` | 5.78 | 1.3 | 1.1% | 5 |
| `stage.readInput` | 0.32 | 0.1 | 0.1% | 5 |
| `notes.chunking` | 0.04 | 0.0 | 0.0% | 5 |
| `stage.writeOutput` | 0.01 | 0.0 | 0.0% | 5 |
| `llm.calls` |  |  |  | 77 |
| `llm.generatedTokens` |  |  |  | 14623 |
| `llm.promptTokens` |  |  |  | 88255 |
| `llm.reusedPromptTokens` |  |  |  | 17951 |

## Quality (first run of each item)

| Set | WER | DER | labelled | correct | failed coverage s |
|---|---|---|---|---|---|
| ami-clean | 26.7% | 25.5% | 96.9% | 96.7% | 104.0 |
| ami-difficult | 24.2% | 27.7% | 96.6% | 97.8% | 13.2 |
| librispeech | 2.3% | – | – | – | 0.0 |

Controls (words; must be 0): music 0, noise 0, silence 0

Boundary fixture: all checks pass

Notes: evidence valid 321/321 items; planted 8/8; injection 10/10; uncertain 37.7%.

