# Perf suite report

Generated 2026-10-22T22:11:07Z · commit `6d83f0a` · Apple M2 Max · macOS 27.0.1 26A434
· worker build **release** · worker QoS userInitiated · Now drawing from 'AC Power'

Contains metrics and item IDs only (no transcript or notes text).

## Gates (M2 Max measured)

| # | Gate | Target (batch / incremental) | Measured | Status |
|---|---|---|---|---|
| G1 | Stop → final transcript with speakers, 60 min | ≤ 60 s / ≤ 20 s | 50 s per 60 min (worst ≥ 50-min meeting): timing-2src-60min/cold 50 s for 60 min; timing-2src-60min/warm 50 s for 60 min; corpus-working-session/default 34 s for 72 min | met (batch) |
| G2 | Stop → notes, 60 min | ≤ 300 s | 148 s per 60 min: timing-2src-60min/cold 149 s; timing-2src-60min/warm 144 s; corpus-working-session/default 95 s | met |
| G3 | Batch path transcript, 60 min | ≤ 60 s | same as G1 (no incremental processing yet) | met |
| G4 | Live text delay | median ≤ 2 s, p95 ≤ 4 s | not measured by perf-suite (T20) | – |
| G5 | Quality guard vs v0 | no breach | **pass** (5 corpus flags for review) | |
| G6 | Capture safety while processing during a call | zero loss | not exercised until T19 | – |
| G7 | Back-to-back meetings | meeting 1 ready while 2 records | not exercised until T19 | – |

## Items

Times in seconds. *exec* is the XPC round trip of each stage; *wait* is time queued behind other work. Stop → transcript and → notes are measured from enqueue (Stop) to commit.

| Item | Run | Audio min | Stop→transcript | Stop→notes | prepare | transcribe (wait) | diarize (wait) | reconcile | notes | Peak worker MiB | OK |
|---|---|---|---|---|---|---|---|---|---|---|---|
| timing-2src-60min | cold | 60.4 | 50.2 | 149.4 | 1.4 | 46.8 (0.6) | 44.9 (0.6) | 0.3 | 98.5 | 3745 | yes |
| timing-2src-60min | warm | 60.4 | 50.5 | 143.9 | 1.4 | 47.0 (0.8) | 44.9 (0.8) | 0.3 | 92.8 | 3935 | yes |
| ami-ES2004a-mix | default | 17.8 | 9.2 | – | 0.2 | 6.6 (0.5) | 8.8 (0.5) | 0.1 | – | 999 | yes |
| ami-IS1009a-mix | default | 14.3 | 7.8 | – | 0.2 | 6.1 (0.1) | 7.4 (0.1) | 0.0 | – | 1024 | yes |
| ami-EN2002a-mix | default | 36.1 | 21.6 | – | 0.4 | 17.2 (0.1) | 20.5 (0.1) | 0.1 | – | 1074 | yes |
| ami-ES2004a-array | default | 17.8 | 8.6 | – | 0.2 | 6.1 (0.2) | 8.2 (0.2) | 0.1 | – | 1098 | yes |
| libri-mic | default | 3.5 | 1.3 | – | 0.0 | 1.2 (0.0) | 0.0 (0.0) | 0.0 | – | 830 | yes |
| control-silence | default | 1.3 | 0.4 | – | 0.0 | 0.1 (0.7) | 0.3 (0.7) | 0.0 | – | 649 | yes |
| control-noise | default | 1.3 | 1.2 | – | 0.0 | 1.1 (0.2) | 0.4 (0.2) | 0.0 | – | 648 | yes |
| control-music | default | 1.3 | 1.2 | – | 0.0 | 1.2 (0.9) | 0.4 (0.9) | 0.0 | – | 648 | yes |
| boundary-tts | default | 0.7 | 0.4 | – | 0.0 | 0.2 (0.4) | 0.4 (0.4) | 0.0 | – | 974 | yes |
| corpus-hangout-ai-session | default | 36.5 | 17.9 | 59.5 | 1.5 | 12.3 (0.2) | 15.8 (0.2) | 0.1 | 41.3 | 3812 | yes |
| corpus-hangout-ruby-session (held out) | default | 39.0 | 20.1 | 64.2 | 1.6 | 14.9 (1.0) | 17.8 (1.0) | 0.2 | 43.7 | 3843 | yes |
| corpus-working-session | default | 71.5 | 34.4 | 95.4 | 3.0 | 21.8 (0.2) | 30.4 (0.2) | 0.2 | 60.6 | 3875 | yes |
| corpus-youtopia-review-session | default | 22.5 | 11.6 | 44.1 | 0.9 | 7.5 (0.9) | 10.3 (0.9) | 0.1 | 32.3 | 3871 | yes |
| corpus-test-youtopia-recording | default | 2.1 | 1.9 | 12.8 | 0.1 | 1.5 (0.9) | 1.7 (0.9) | 0.0 | 10.9 | 3730 | yes |
| notes-planted-60min | default | 0.0 | – | 124.2 | – | – | – | – | 123.9 | 3767 | yes |
| notes-planted-120min | default | 0.0 | – | 266.4 | – | – | – | – | 265.7 | 3799 | yes |
| notes-inject-0 | default | 0.0 | – | 4.5 | – | – | – | – | 4.5 | 3799 | yes |
| notes-inject-1 | default | 0.0 | – | 16.1 | – | – | – | – | 16.1 | 3799 | yes |
| notes-inject-2 | default | 0.0 | – | 17.9 | – | – | – | – | 17.9 | 3808 | yes |
| notes-inject-3 | default | 0.0 | – | 16.5 | – | – | – | – | 16.5 | 3808 | yes |
| notes-inject-4 | default | 0.0 | – | 16.9 | – | – | – | – | 16.8 | 3808 | yes |
| notes-inject-5 | default | 0.0 | – | 17.5 | – | – | – | – | 17.4 | 3808 | yes |
| notes-inject-6 | default | 0.0 | – | 16.0 | – | – | – | – | 15.9 | 3808 | yes |
| notes-inject-7 | default | 0.0 | – | 16.8 | – | – | – | – | 16.7 | 3808 | yes |
| notes-inject-8 | default | 0.0 | – | 17.3 | – | – | – | – | 17.3 | 3808 | yes |
| notes-inject-9 | default | 0.0 | – | 18.5 | – | – | – | – | 18.5 | 3808 | yes |

## Where the time goes

Totals over 15 audio items (5.44 h of audio, first run each). Rates are seconds per hour of audio. Counters have no time.

### prepare

exec 9.8 s (1.8 s/h) = worker 9.8 s + IPC/launch 0.0 s; app-side input 0.3 s, commit 0.0 s.

| Interval | Seconds | s per audio hour | Share of worker time | Count |
|---|---|---|---|---|
| `prepare.total` | 9.68 | 1.8 | 98.9% | 15 |
| `prepare.readSegment` | 6.29 | 1.2 | 64.3% | 11674 |
| `prepare.downmix` | 1.62 | 0.3 | 16.5% | 11674 |
| `prepare.resample` | 1.17 | 0.2 | 11.9% | 11674 |
| `prepare.write` | 0.51 | 0.1 | 5.2% | 11691 |
| `stage.readInput` | 0.10 | 0.0 | 1.0% | 15 |
| `stage.writeOutput` | 0.00 | 0.0 | 0.0% | 15 |
| `prepare.segments` |  |  |  | 11674 |

### transcribe

exec 144.7 s (26.6 s/h) = worker 144.7 s + IPC/launch 0.0 s; app-side input 0.0 s, commit 2.1 s.

| Interval | Seconds | s per audio hour | Share of worker time | Count |
|---|---|---|---|---|
| `asr.decode.audioSeconds` (audio decoded, not time) | 35606 | 6545 | | |
| `asr.decode` | 255.69 | 47.0 | 176.7% | 2669 |
| `asr.decode.first` | 225.70 | 41.5 | 156.0% | 2357 |
| `asr.decode.retries` | 30.39 | 5.6 | 21.0% | 128 |
| `asr.vad.infer` | 22.14 | 4.1 | 15.3% | 50 |
| `asr.plan` | 12.04 | 2.2 | 8.3% | 17 |
| `asr.checkpoint.write` | 1.78 | 0.3 | 1.2% | 2441 |
| `model.load.asr` | 1.51 | 0.3 | 1.0% | 6 |
| `asr.window.read` | 0.74 | 0.1 | 0.5% | 5110 |
| `stage.writeOutput` | 0.55 | 0.1 | 0.4% | 15 |
| `asr.vad.read` | 0.20 | 0.0 | 0.1% | 50 |
| `asr.checkpoint.read` | 0.07 | 0.0 | 0.0% | 2441 |
| `asr.assemble` | 0.04 | 0.0 | 0.0% | 17 |
| `stage.readInput` | 0.00 | 0.0 | 0.0% | 15 |
| `asr.windows` |  |  |  | 2441 |
| `asr.windows.retried.garbled` |  |  |  | 1 |
| `asr.windows.retried.underYield` |  |  |  | 127 |
| `asr.windows.silent` |  |  |  | 84 |

### diarize

exec 167.3 s (30.7 s/h) = worker 167.2 s + IPC/launch 0.0 s; app-side input 0.0 s, commit 0.0 s.

| Interval | Seconds | s per audio hour | Share of worker time | Count |
|---|---|---|---|---|
| `diarize.engine` | 164.99 | 30.3 | 98.6% | 18 |
| `diarize.engine.embeddings` | 160.19 | 29.4 | 95.8% | 15 |
| `diarize.engine.segmentation` | 56.45 | 10.4 | 33.8% | 15 |
| `diarize.engine.clustering` | 2.43 | 0.4 | 1.5% | 15 |
| `model.load.diarization` | 0.46 | 0.1 | 0.3% | 6 |
| `diarize.engine.audioLoading` | 0.27 | 0.0 | 0.2% | 15 |
| `diarize.read` | 0.06 | 0.0 | 0.0% | 6 |
| `diarize.echo` | 0.03 | 0.0 | 0.0% | 2 |
| `stage.writeOutput` | 0.02 | 0.0 | 0.0% | 15 |
| `stage.readInput` | 0.00 | 0.0 | 0.0% | 15 |
| `diarize.engine.postProcessing` |  |  |  | 15 |

### reconcile

exec 1.2 s (0.2 s/h) = worker 1.2 s + IPC/launch 0.0 s; app-side input 1.5 s, commit 2.3 s.

| Interval | Seconds | s per audio hour | Share of worker time | Count |
|---|---|---|---|---|
| `stage.writeOutput` | 0.66 | 0.1 | 54.3% | 15 |
| `stage.readInput` | 0.47 | 0.1 | 38.9% | 15 |

### notes

exec 287.3 s (52.8 s/h) = worker 287.3 s + IPC/launch 0.0 s; app-side input 0.9 s, commit 0.9 s.

| Interval | Seconds | s per audio hour | Share of worker time | Count |
|---|---|---|---|---|
| `notes.mapVerify` | 260.12 | 47.8 | 90.5% | 6 |
| `llm.generate` | 152.89 | 28.1 | 53.2% | 12 |
| `llm.prefill` | 126.86 | 23.3 | 44.2% | 12 |
| `notes.overview` | 19.74 | 3.6 | 6.9% | 6 |
| `model.load.notes` | 6.53 | 1.2 | 2.3% | 6 |
| `llm.generate.sampling` | 2.19 | 0.4 | 0.8% | 12 |
| `stage.readInput` | 0.42 | 0.1 | 0.1% | 6 |
| `notes.chunking` | 0.06 | 0.0 | 0.0% | 6 |
| `stage.writeOutput` | 0.01 | 0.0 | 0.0% | 6 |
| `llm.calls` |  |  |  | 105 |
| `llm.generatedTokens` |  |  |  | 16199 |
| `llm.promptTokens` |  |  |  | 133055 |
| `llm.reusedPromptTokens` |  |  |  | 13119 |
| `llm.steps` |  |  |  | 7631 |

## Quality (first run of each item)

| Set | WER | DER | labelled | correct | failed coverage s |
|---|---|---|---|---|---|
| ami-clean | 26.7% | 25.6% | 96.9% | 96.7% | 104.0 |
| ami-difficult | 24.2% | 27.5% | 96.2% | 97.9% | 13.2 |
| librispeech | 2.3% | – | – | – | 0.0 |

Controls (words; must be 0): music 0, noise 0, silence 0

Boundary fixture: all checks pass

Notes: evidence valid 336/336 items; planted 8/8; injection 10/10; uncertain 33.0%.

## Comparison with the baseline

Baseline: `/Users/alex/sandbox/amaranth-v2/Tests/Data/Recordings/baseline-v0`

**G5 holds**: no breach.

Transcripts not identical to the baseline (information; required only for pure refactors): none

Corpus meetings flagged for review (not breaches; user decision 2026-10-22): 
- `corpus:notes:corpus-hangout-ai-session`: notes item overlap 29.2% < 70%
- `corpus:notes:corpus-hangout-ruby-session`: notes item overlap 0.0% < 70%
- `corpus:notes:corpus-working-session`: notes item overlap 8.3% < 70%
- `corpus:notes:corpus-youtopia-review-session`: notes item overlap 31.8% < 70%
- `corpus:notes:corpus-test-youtopia-recording`: notes item overlap 40.0% < 70%

