# Perf suite report

Generated 2026-10-24T00:49:57Z · commit `0ee32cc` · Apple M2 Max · macOS 27.0.1 26A434
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
| corpus-hangout-ai-session | cold | 36.5 | 18.1 | 49.7 | 1.5 | 12.5 (0.7) | 16.0 (0.7) | 0.1 | 31.4 | 3689 | yes |
| corpus-youtopia-review-session | default | 22.5 | 11.6 | 41.8 | 0.9 | 7.5 (0.7) | 10.3 (0.7) | 0.1 | 30.0 | 3686 | yes |
| corpus-test-youtopia-recording | default | 2.1 | 1.9 | 13.2 | 0.1 | 1.5 (0.0) | 1.7 (0.0) | 0.0 | 11.2 | 3663 | yes |
| notes-planted-60min | default | 0.0 | – | 118.5 | – | – | – | – | 118.1 | 3699 | yes |
| notes-inject-0 | default | 0.0 | – | 8.9 | – | – | – | – | 8.9 | 3699 | yes |
| notes-inject-1 | default | 0.0 | – | 20.3 | – | – | – | – | 20.2 | 3699 | yes |
| notes-inject-2 | default | 0.0 | – | 8.9 | – | – | – | – | 8.8 | 3699 | yes |
| notes-inject-3 | default | 0.0 | – | 8.5 | – | – | – | – | 8.4 | 3699 | yes |
| notes-inject-4 | default | 0.0 | – | 20.3 | – | – | – | – | 20.2 | 3699 | yes |
| notes-inject-5 | default | 0.0 | – | 20.4 | – | – | – | – | 20.4 | 3699 | yes |
| notes-inject-6 | default | 0.0 | – | 9.1 | – | – | – | – | 9.1 | 3699 | yes |
| notes-inject-7 | default | 0.0 | – | 9.0 | – | – | – | – | 8.9 | 3699 | yes |
| notes-inject-8 | default | 0.0 | – | 18.7 | – | – | – | – | 18.6 | 3699 | yes |
| notes-inject-9 | default | 0.0 | – | 9.5 | – | – | – | – | 9.5 | 3699 | yes |

## Where the time goes

Totals over 3 audio items (1.02 h of audio, first run each). Rates are seconds per hour of audio. Counters have no time.

### prepare

exec 2.6 s (2.5 s/h) = worker 2.6 s + IPC/launch 0.0 s; app-side input 0.0 s, commit 0.0 s.

| Interval | Seconds | s per audio hour | Share of worker time | Count |
|---|---|---|---|---|
| `prepare.total` | 2.54 | 2.5 | 99.3% | 3 |
| `prepare.readSegment` | 1.50 | 1.5 | 58.5% | 1894 |
| `prepare.downmix` | 0.55 | 0.5 | 21.5% | 1894 |
| `prepare.resample` | 0.41 | 0.4 | 15.9% | 1894 |
| `prepare.write` | 0.08 | 0.1 | 3.1% | 1898 |
| `stage.readInput` | 0.02 | 0.0 | 0.6% | 3 |
| `stage.writeOutput` | 0.00 | 0.0 | 0.0% | 3 |
| `prepare.segments` |  |  |  | 1894 |

### transcribe

exec 21.5 s (21.1 s/h) = worker 21.5 s + IPC/launch 0.0 s; app-side input 0.0 s, commit 0.4 s.

| Interval | Seconds | s per audio hour | Share of worker time | Count |
|---|---|---|---|---|
| `asr.decode.audioSeconds` (audio decoded, not time) | 5380 | 5281 | | |
| `asr.decode` | 36.24 | 35.6 | 168.5% | 397 |
| `asr.decode.first` | 34.86 | 34.2 | 162.0% | 386 |
| `asr.vad.infer` | 3.49 | 3.4 | 16.2% | 9 |
| `asr.plan` | 1.98 | 1.9 | 9.2% | 4 |
| `asr.decode.retries` | 1.44 | 1.4 | 6.7% | 9 |
| `model.load.asr` | 0.77 | 0.8 | 3.6% | 3 |
| `asr.checkpoint.write` | 0.27 | 0.3 | 1.2% | 390 |
| `asr.window.read` | 0.11 | 0.1 | 0.5% | 787 |
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
| `diarize.engine` | 27.00 | 26.5 | 96.1% | 3 |
| `diarize.engine.embeddings` | 26.26 | 25.8 | 93.5% | 3 |
| `diarize.engine.segmentation` | 10.92 | 10.7 | 38.9% | 3 |
| `diarize.engine.clustering` | 0.42 | 0.4 | 1.5% | 3 |
| `model.load.diarization` | 0.23 | 0.2 | 0.8% | 3 |
| `diarize.engine.audioLoading` | 0.08 | 0.1 | 0.3% | 3 |
| `diarize.echo` | 0.00 | 0.0 | 0.0% | 1 |
| `stage.writeOutput` | 0.00 | 0.0 | 0.0% | 3 |
| `stage.readInput` | 0.00 | 0.0 | 0.0% | 3 |
| `diarize.engine.postProcessing` |  |  |  | 3 |

### reconcile

exec 0.2 s (0.2 s/h) = worker 0.2 s + IPC/launch 0.0 s; app-side input 0.3 s, commit 0.4 s.

| Interval | Seconds | s per audio hour | Share of worker time | Count |
|---|---|---|---|---|
| `stage.writeOutput` | 0.12 | 0.1 | 54.5% | 3 |
| `stage.readInput` | 0.09 | 0.1 | 38.9% | 3 |

### notes

exec 72.6 s (71.2 s/h) = worker 72.6 s + IPC/launch 0.0 s; app-side input 0.2 s, commit 0.2 s.

| Interval | Seconds | s per audio hour | Share of worker time | Count |
|---|---|---|---|---|
| `notes.mapVerify` | 53.77 | 52.8 | 74.1% | 3 |
| `llm.generate` | 36.92 | 36.2 | 50.9% | 9 |
| `llm.prefill` | 33.93 | 33.3 | 46.8% | 9 |
| `notes.overview` | 17.14 | 16.8 | 23.6% | 3 |
| `model.load.notes` | 1.45 | 1.4 | 2.0% | 3 |
| `llm.generate.sampling` | 0.54 | 0.5 | 0.7% | 9 |
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

