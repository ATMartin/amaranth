# Perf suite report

Generated 2026-10-24T00:08:13Z · commit `2ce6fd0` · Apple M2 Max · macOS 27.0.1 26A434
· worker build **release** · worker QoS userInitiated · Now drawing from 'AC Power'

Contains metrics and item IDs only (no transcript or notes text).

## Gates (M2 Max measured)

| # | Gate | Target (batch / incremental) | Measured | Status |
|---|---|---|---|---|
| G1 | Stop → final transcript with speakers, 60 min | ≤ 60 s / ≤ 20 s | batch: – s per 60 min (worst ≥ 50-min meeting): no meeting ≥ 50 min. While recording: not run | – (batch); – (while recording) |
| G2 | Stop → notes, 60 min | ≤ 300 s | – s per 60 min: no meeting ≥ 50 min | – |
| G3 | Batch path transcript, 60 min | ≤ 60 s | same as G1 batch | – |
| G4 | Live text delay | median ≤ 2 s, p95 ≤ 4 s | not measured by perf-suite (T20) | – |
| G5 | Quality guard vs v0 | no breach | **pass** (3 corpus flags for review) | |
| G6 | Capture safety while processing during a call | zero loss | measured by `--self-test live-load` (processing/0003) | – |
| G7 | Back-to-back meetings | meeting 1 ready while 2 records | not run | – |

## Items

Times in seconds. *exec* is the XPC round trip of each stage; *wait* is time queued behind other work. Stop → transcript and → notes are measured from enqueue (Stop) to commit.

| Item | Run | Audio min | Stop→transcript | Stop→notes | prepare | transcribe (wait) | diarize (wait) | reconcile | notes | Peak worker MiB | OK |
|---|---|---|---|---|---|---|---|---|---|---|---|
| corpus-hangout-ai-session | cold | 36.5 | 18.1 | 49.7 | 1.5 | 12.5 (0.2) | 16.0 (0.2) | 0.1 | 31.3 | 3705 | yes |
| corpus-youtopia-review-session | default | 22.5 | 11.7 | 41.6 | 1.0 | 7.6 (0.4) | 10.4 (0.4) | 0.1 | 29.8 | 3705 | yes |
| corpus-test-youtopia-recording | default | 2.1 | 1.9 | 13.1 | 0.1 | 1.5 (0.9) | 1.8 (0.9) | 0.0 | 11.2 | 3683 | yes |
| notes-planted-60min | default | 0.0 | – | 118.2 | – | – | – | – | 117.8 | 3718 | yes |
| notes-inject-0 | default | 0.0 | – | 8.9 | – | – | – | – | 8.9 | 3718 | yes |
| notes-inject-1 | default | 0.0 | – | 20.1 | – | – | – | – | 20.1 | 3718 | yes |
| notes-inject-2 | default | 0.0 | – | 8.8 | – | – | – | – | 8.8 | 3718 | yes |
| notes-inject-3 | default | 0.0 | – | 8.4 | – | – | – | – | 8.4 | 3718 | yes |
| notes-inject-4 | default | 0.0 | – | 20.0 | – | – | – | – | 20.0 | 3718 | yes |
| notes-inject-5 | default | 0.0 | – | 19.8 | – | – | – | – | 19.7 | 3718 | yes |
| notes-inject-6 | default | 0.0 | – | 9.0 | – | – | – | – | 9.0 | 3718 | yes |
| notes-inject-7 | default | 0.0 | – | 8.8 | – | – | – | – | 8.8 | 3718 | yes |
| notes-inject-8 | default | 0.0 | – | 17.9 | – | – | – | – | 17.8 | 3718 | yes |
| notes-inject-9 | default | 0.0 | – | 9.0 | – | – | – | – | 8.9 | 3718 | yes |

## Where the time goes

Totals over 3 audio items (1.02 h of audio, first run each). Rates are seconds per hour of audio. Counters have no time.

### prepare

exec 2.6 s (2.5 s/h) = worker 2.6 s + IPC/launch 0.0 s; app-side input 0.0 s, commit 0.0 s.

| Interval | Seconds | s per audio hour | Share of worker time | Count |
|---|---|---|---|---|
| `prepare.total` | 2.55 | 2.5 | 99.3% | 3 |
| `prepare.readSegment` | 1.50 | 1.5 | 58.3% | 1894 |
| `prepare.downmix` | 0.55 | 0.5 | 21.2% | 1894 |
| `prepare.resample` | 0.41 | 0.4 | 16.0% | 1894 |
| `prepare.write` | 0.09 | 0.1 | 3.5% | 1898 |
| `stage.readInput` | 0.02 | 0.0 | 0.6% | 3 |
| `stage.writeOutput` | 0.00 | 0.0 | 0.0% | 3 |
| `prepare.segments` |  |  |  | 1894 |

### transcribe

exec 21.6 s (21.2 s/h) = worker 21.6 s + IPC/launch 0.0 s; app-side input 0.0 s, commit 0.4 s.

| Interval | Seconds | s per audio hour | Share of worker time | Count |
|---|---|---|---|---|
| `asr.decode.audioSeconds` (audio decoded, not time) | 5380 | 5281 | | |
| `asr.decode` | 36.34 | 35.7 | 168.5% | 397 |
| `asr.decode.first` | 34.96 | 34.3 | 162.1% | 386 |
| `asr.vad.infer` | 3.52 | 3.5 | 16.3% | 9 |
| `asr.plan` | 2.03 | 2.0 | 9.4% | 4 |
| `asr.decode.retries` | 1.44 | 1.4 | 6.7% | 9 |
| `model.load.asr` | 0.72 | 0.7 | 3.3% | 3 |
| `asr.checkpoint.write` | 0.28 | 0.3 | 1.3% | 390 |
| `asr.window.read` | 0.12 | 0.1 | 0.5% | 787 |
| `stage.writeOutput` | 0.10 | 0.1 | 0.5% | 3 |
| `asr.vad.read` | 0.04 | 0.0 | 0.2% | 9 |
| `asr.checkpoint.read` | 0.01 | 0.0 | 0.1% | 390 |
| `asr.assemble` | 0.01 | 0.0 | 0.0% | 4 |
| `stage.readInput` | 0.00 | 0.0 | 0.0% | 3 |
| `asr.reuse.validate` | 0.00 | 0.0 | 0.0% | 4 |
| `asr.windows` |  |  |  | 390 |
| `asr.windows.retried.underYield` |  |  |  | 9 |
| `asr.windows.silent` |  |  |  | 4 |

### diarize

exec 28.1 s (27.6 s/h) = worker 28.1 s + IPC/launch 0.0 s; app-side input 0.0 s, commit 0.0 s.

| Interval | Seconds | s per audio hour | Share of worker time | Count |
|---|---|---|---|---|
| `diarize.engine` | 27.12 | 26.6 | 96.4% | 3 |
| `diarize.engine.embeddings` | 26.37 | 25.9 | 93.7% | 3 |
| `diarize.engine.segmentation` | 11.03 | 10.8 | 39.2% | 3 |
| `diarize.engine.clustering` | 0.42 | 0.4 | 1.5% | 3 |
| `model.load.diarization` | 0.22 | 0.2 | 0.8% | 3 |
| `diarize.engine.audioLoading` | 0.10 | 0.1 | 0.3% | 3 |
| `diarize.echo` | 0.00 | 0.0 | 0.0% | 1 |
| `stage.writeOutput` | 0.00 | 0.0 | 0.0% | 3 |
| `stage.readInput` | 0.00 | 0.0 | 0.0% | 3 |
| `diarize.engine.postProcessing` |  |  |  | 3 |

### reconcile

exec 0.2 s (0.2 s/h) = worker 0.2 s + IPC/launch 0.0 s; app-side input 0.3 s, commit 0.4 s.

| Interval | Seconds | s per audio hour | Share of worker time | Count |
|---|---|---|---|---|
| `stage.writeOutput` | 0.12 | 0.1 | 54.0% | 3 |
| `stage.readInput` | 0.09 | 0.1 | 39.4% | 3 |

### notes

exec 72.3 s (71.0 s/h) = worker 72.3 s + IPC/launch 0.0 s; app-side input 0.2 s, commit 0.2 s.

| Interval | Seconds | s per audio hour | Share of worker time | Count |
|---|---|---|---|---|
| `notes.mapVerify` | 53.58 | 52.6 | 74.1% | 3 |
| `llm.generate` | 36.90 | 36.2 | 51.0% | 9 |
| `llm.prefill` | 33.71 | 33.1 | 46.6% | 9 |
| `notes.overview` | 17.09 | 16.8 | 23.6% | 3 |
| `model.load.notes` | 1.41 | 1.4 | 1.9% | 3 |
| `llm.generate.sampling` | 0.54 | 0.5 | 0.8% | 9 |
| `stage.readInput` | 0.10 | 0.1 | 0.1% | 3 |
| `notes.chunking` | 0.02 | 0.0 | 0.0% | 3 |
| `stage.writeOutput` | 0.00 | 0.0 | 0.0% | 3 |
| `llm.calls` |  |  |  | 33 |
| `llm.generatedTokens` |  |  |  | 3387 |
| `llm.promptTokens` |  |  |  | 35517 |
| `llm.reusedPromptTokens` |  |  |  | 1247 |
| `llm.steps` |  |  |  | 2788 |

## Quality (first run of each item)

| Set | WER | DER | labelled | correct | failed coverage s |
|---|---|---|---|---|---|

Controls (words; must be 0): 

Boundary fixture: not run

Notes: evidence valid 108/108 items; planted 2/2; injection 10/10; uncertain 25.0%.

## Comparison with the baseline

Baseline: `/Users/alex/sandbox/amaranth-v2/Tests/Data/Recordings/baseline-v0`

**G5 holds**: no breach.

Not checked in this run: set ami-clean, set ami-difficult, set librispeech, control music, control noise, control silence, boundary fixtures

Transcripts not identical to the baseline (information; required only for pure refactors): none

Corpus meetings flagged for review (not breaches; user decision 2026-10-22): 
- `corpus:notes:corpus-hangout-ai-session`: notes item overlap 15.0% < 70%
- `corpus:notes:corpus-youtopia-review-session`: notes item overlap 9.1% < 70%
- `corpus:notes:corpus-test-youtopia-recording`: notes item overlap 10.0% < 70%

