# Perf suite report

Generated 2026-10-23T23:48:55Z · commit `2ce6fd0` · Apple M2 Max · macOS 27.0.1 26A434
· worker build **release** · worker QoS userInitiated · Now drawing from 'AC Power'

Contains metrics and item IDs only (no transcript or notes text).

## Gates (M2 Max measured)

| # | Gate | Target (batch / incremental) | Measured | Status |
|---|---|---|---|---|
| G1 | Stop → final transcript with speakers, 60 min | ≤ 60 s / ≤ 20 s | batch: – s per 60 min (worst ≥ 50-min meeting): no meeting ≥ 50 min. While recording: not run | – (batch); – (while recording) |
| G2 | Stop → notes, 60 min | ≤ 300 s | – s per 60 min: no meeting ≥ 50 min | – |
| G3 | Batch path transcript, 60 min | ≤ 60 s | same as G1 batch | – |
| G4 | Live text delay | median ≤ 2 s, p95 ≤ 4 s | not measured by perf-suite (T20) | – |
| G5 | Quality guard vs v0 | no breach | **FAIL** (1 breaches) | |
| G6 | Capture safety while processing during a call | zero loss | measured by `--self-test live-load` (processing/0003) | – |
| G7 | Back-to-back meetings | meeting 1 ready while 2 records | not run | – |

## Items

Times in seconds. *exec* is the XPC round trip of each stage; *wait* is time queued behind other work. Stop → transcript and → notes are measured from enqueue (Stop) to commit.

| Item | Run | Audio min | Stop→transcript | Stop→notes | prepare | transcribe (wait) | diarize (wait) | reconcile | notes | Peak worker MiB | OK |
|---|---|---|---|---|---|---|---|---|---|---|---|
| corpus-hangout-ai-session | cold | 36.5 | 18.1 | 46.7 | 1.5 | 12.5 (0.9) | 16.1 (0.9) | 0.1 | 28.3 | 3691 | yes |
| corpus-youtopia-review-session | default | 22.5 | 11.7 | 40.9 | 0.9 | 7.5 (0.3) | 10.4 (0.3) | 0.1 | 29.1 | 3687 | yes |
| corpus-test-youtopia-recording | default | 2.1 | 1.9 | 12.4 | 0.1 | 1.5 (0.6) | 1.8 (0.6) | 0.0 | 10.5 | 3667 | yes |
| notes-planted-60min | default | 0.0 | – | 118.1 | – | – | – | – | 117.8 | 3703 | yes |
| notes-inject-0 | default | 0.0 | – | 7.5 | – | – | – | – | 7.4 | 3703 | yes |
| notes-inject-1 | default | 0.0 | – | 17.9 | – | – | – | – | 17.8 | 3703 | yes |
| notes-inject-2 | default | 0.0 | – | 8.0 | – | – | – | – | 8.0 | 3703 | yes |
| notes-inject-3 | default | 0.0 | – | 7.6 | – | – | – | – | 7.5 | 3703 | yes |
| notes-inject-4 | default | 0.0 | – | 18.3 | – | – | – | – | 18.3 | 3703 | yes |
| notes-inject-5 | default | 0.0 | – | 19.4 | – | – | – | – | 19.4 | 3703 | yes |
| notes-inject-6 | default | 0.0 | – | 7.9 | – | – | – | – | 7.9 | 3703 | yes |
| notes-inject-7 | default | 0.0 | – | 7.7 | – | – | – | – | 7.6 | 3703 | yes |
| notes-inject-8 | default | 0.0 | – | 15.7 | – | – | – | – | 15.7 | 3703 | yes |
| notes-inject-9 | default | 0.0 | – | 8.1 | – | – | – | – | 8.0 | 3703 | yes |

## Where the time goes

Totals over 3 audio items (1.02 h of audio, first run each). Rates are seconds per hour of audio. Counters have no time.

### prepare

exec 2.6 s (2.5 s/h) = worker 2.6 s + IPC/launch 0.0 s; app-side input 0.0 s, commit 0.0 s.

| Interval | Seconds | s per audio hour | Share of worker time | Count |
|---|---|---|---|---|
| `prepare.total` | 2.55 | 2.5 | 99.3% | 3 |
| `prepare.readSegment` | 1.51 | 1.5 | 58.7% | 1894 |
| `prepare.downmix` | 0.54 | 0.5 | 21.2% | 1894 |
| `prepare.resample` | 0.40 | 0.4 | 15.7% | 1894 |
| `prepare.write` | 0.08 | 0.1 | 3.3% | 1898 |
| `stage.readInput` | 0.02 | 0.0 | 0.6% | 3 |
| `stage.writeOutput` | 0.00 | 0.0 | 0.0% | 3 |
| `prepare.segments` |  |  |  | 1894 |

### transcribe

exec 21.4 s (21.0 s/h) = worker 21.4 s + IPC/launch 0.0 s; app-side input 0.0 s, commit 0.4 s.

| Interval | Seconds | s per audio hour | Share of worker time | Count |
|---|---|---|---|---|
| `asr.decode.audioSeconds` (audio decoded, not time) | 5380 | 5281 | | |
| `asr.decode` | 36.12 | 35.5 | 168.5% | 397 |
| `asr.decode.first` | 34.74 | 34.1 | 162.1% | 386 |
| `asr.vad.infer` | 3.51 | 3.4 | 16.4% | 9 |
| `asr.plan` | 1.95 | 1.9 | 9.1% | 4 |
| `asr.decode.retries` | 1.44 | 1.4 | 6.7% | 9 |
| `model.load.asr` | 0.77 | 0.8 | 3.6% | 3 |
| `asr.checkpoint.write` | 0.27 | 0.3 | 1.3% | 390 |
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

exec 28.2 s (27.7 s/h) = worker 28.2 s + IPC/launch 0.0 s; app-side input 0.0 s, commit 0.0 s.

| Interval | Seconds | s per audio hour | Share of worker time | Count |
|---|---|---|---|---|
| `diarize.engine` | 27.10 | 26.6 | 96.2% | 3 |
| `diarize.engine.embeddings` | 26.36 | 25.9 | 93.5% | 3 |
| `diarize.engine.segmentation` | 11.12 | 10.9 | 39.5% | 3 |
| `diarize.engine.clustering` | 0.41 | 0.4 | 1.4% | 3 |
| `model.load.diarization` | 0.22 | 0.2 | 0.8% | 3 |
| `diarize.engine.audioLoading` | 0.11 | 0.1 | 0.4% | 3 |
| `diarize.echo` | 0.00 | 0.0 | 0.0% | 1 |
| `stage.writeOutput` | 0.00 | 0.0 | 0.0% | 3 |
| `stage.readInput` | 0.00 | 0.0 | 0.0% | 3 |
| `diarize.engine.postProcessing` |  |  |  | 3 |

### reconcile

exec 0.2 s (0.2 s/h) = worker 0.2 s + IPC/launch 0.0 s; app-side input 0.3 s, commit 0.4 s.

| Interval | Seconds | s per audio hour | Share of worker time | Count |
|---|---|---|---|---|
| `stage.writeOutput` | 0.12 | 0.1 | 54.4% | 3 |
| `stage.readInput` | 0.08 | 0.1 | 39.0% | 3 |

### notes

exec 67.9 s (66.6 s/h) = worker 67.9 s + IPC/launch 0.0 s; app-side input 0.2 s, commit 0.2 s.

| Interval | Seconds | s per audio hour | Share of worker time | Count |
|---|---|---|---|---|
| `notes.mapVerify` | 53.55 | 52.6 | 78.9% | 3 |
| `llm.generate` | 34.08 | 33.5 | 50.2% | 6 |
| `llm.prefill` | 32.10 | 31.5 | 47.3% | 6 |
| `notes.overview` | 12.67 | 12.4 | 18.7% | 3 |
| `model.load.notes` | 1.44 | 1.4 | 2.1% | 3 |
| `llm.generate.sampling` | 0.50 | 0.5 | 0.7% | 6 |
| `stage.readInput` | 0.10 | 0.1 | 0.1% | 3 |
| `notes.chunking` | 0.02 | 0.0 | 0.0% | 3 |
| `stage.writeOutput` | 0.00 | 0.0 | 0.0% | 3 |
| `llm.calls` |  |  |  | 29 |
| `llm.generatedTokens` |  |  |  | 3146 |
| `llm.promptTokens` |  |  |  | 32739 |
| `llm.reusedPromptTokens` |  |  |  | 96 |
| `llm.steps` |  |  |  | 2566 |

## Quality (first run of each item)

| Set | WER | DER | labelled | correct | failed coverage s |
|---|---|---|---|---|---|

Controls (words; must be 0): 

Boundary fixture: not run

Notes: evidence valid 107/107 items; planted 2/2; injection 7/10; uncertain 25.2%.

## Comparison with the baseline

Baseline: `/Users/alex/sandbox/amaranth-v2/Tests/Data/Recordings/baseline-v0`

**G5 breached:**
- `notes:injection`: injection 7/10

Not checked in this run: set ami-clean, set ami-difficult, set librispeech, control music, control noise, control silence, boundary fixtures

Transcripts not identical to the baseline (information; required only for pure refactors): none

Corpus meetings flagged for review (not breaches; user decision 2026-10-22): 
- `corpus:notes:corpus-hangout-ai-session`: notes item overlap 15.0% < 70%
- `corpus:notes:corpus-youtopia-review-session`: notes item overlap 9.1% < 70%
- `corpus:notes:corpus-test-youtopia-recording`: notes item overlap 10.0% < 70%

