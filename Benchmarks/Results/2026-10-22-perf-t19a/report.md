# Perf suite report

Generated 2026-10-23T03:39:03Z · commit `00d48fa` · Apple M2 Max · macOS 27.0.1 26A434
· worker build **release** · worker QoS userInitiated · Now drawing from 'AC Power'

Contains metrics and item IDs only (no transcript or notes text).

## Gates (M2 Max measured)

| # | Gate | Target (batch / incremental) | Measured | Status |
|---|---|---|---|---|
| G1 | Stop → final transcript with speakers, 60 min | ≤ 60 s / ≤ 20 s | batch: 50 s per 60 min (worst ≥ 50-min meeting): timing-2src-60min/cold 50 s for 60 min; timing-2src-60min/warm 50 s for 60 min; corpus-working-session/default 34 s for 72 min. While recording: timing-2src-60min 21 s for 60 min; corpus-working-session 23 s for 72 min | met (batch); **not met** (while recording) |
| G2 | Stop → notes, 60 min | ≤ 300 s | 144 s per 60 min: timing-2src-60min/cold 145 s; timing-2src-60min/warm 144 s; corpus-working-session/default 95 s | met |
| G3 | Batch path transcript, 60 min | ≤ 60 s | same as G1 batch | met |
| G4 | Live text delay | median ≤ 2 s, p95 ≤ 4 s | not measured by perf-suite (T20) | – |
| G5 | Quality guard vs v0 | no breach | **pass** (6 corpus flags for review) | |
| G6 | Capture safety while processing during a call | zero loss | measured by `--self-test live-load` (processing/0003) | – |
| G7 | Back-to-back meetings | meeting 1 ready while 2 records | timing-2src-60min: ready 22 s after Stop, next Stop at 363 s, 0 stages left | met |

## Processing while recording (T19)

Replayed at 10× realtime. *Final at Stop*: end of final-quality text per source when recording stopped. *Reused*: windows the transcription stage took from incremental results (identical window and audio).

| Item | Run | Audio min | Stop→transcript | transcribe exec | diarize exec | Requests (busy, failed, paused) | Windows decoded | Final at Stop (s) | Reused windows | Identical to batch run |
|---|---|---|---|---|---|---|---|---|---|---|
| timing-2src-60min | b2b-1 | 60.4 | 21.7 | 1.7 | 19.6 | 72 (0, 0, 0) | 780/780 | microphone 3568, systemOutput 3566 | 780 | yes |
| timing-2src-60min | b2b-2 | 60.4 | 20.9 | 1.5 | 18.8 | 72 (0, 0, 0) | 780/780 | microphone 3568, systemOutput 3566 | 780 | yes |
| timing-2src-60min | incremental | 60.4 | 21.0 | 1.7 | 19.0 | 72 (0, 0, 0) | 780/780 | microphone 3568, systemOutput 3566 | 780 | yes |
| corpus-working-session | incremental | 71.5 | 23.3 | 0.8 | 19.5 | 85 (0, 0, 0) | 431/431 | systemOutput 4220 | 431 | yes |

## Items

Times in seconds. *exec* is the XPC round trip of each stage; *wait* is time queued behind other work. Stop → transcript and → notes are measured from enqueue (Stop) to commit.

| Item | Run | Audio min | Stop→transcript | Stop→notes | prepare | transcribe (wait) | diarize (wait) | reconcile | notes | Peak worker MiB | OK |
|---|---|---|---|---|---|---|---|---|---|---|---|
| timing-2src-60min | b2b-1 | 60.4 | 21.7 | – | 0.5 | 1.7 (0.1) | 19.6 (0.1) | 0.3 | – | 951 | yes |
| timing-2src-60min | b2b-2 | 60.4 | 20.9 | – | 0.5 | 1.5 (0.8) | 18.8 (0.8) | 0.3 | – | 951 | yes |
| timing-2src-60min | cold | 60.4 | 50.1 | 145.3 | 1.4 | 46.7 (0.8) | 45.0 (0.8) | 0.3 | 94.5 | 3727 | yes |
| timing-2src-60min | incremental | 60.4 | 21.0 | 114.4 | 0.5 | 1.7 (0.3) | 19.0 (0.3) | 0.3 | 92.7 | 3921 | yes |
| timing-2src-60min | warm | 60.4 | 50.4 | 144.4 | 1.4 | 47.0 (0.6) | 44.4 (0.6) | 0.3 | 93.4 | 3890 | yes |
| ami-ES2004a-mix | default | 17.8 | 8.9 | – | 0.2 | 6.3 (0.7) | 8.4 (0.7) | 0.1 | – | 1004 | yes |
| ami-IS1009a-mix | default | 14.3 | 7.8 | – | 0.2 | 6.1 (0.3) | 7.4 (0.3) | 0.0 | – | 989 | yes |
| ami-EN2002a-mix | default | 36.1 | 21.4 | – | 0.4 | 17.4 (0.8) | 20.3 (0.8) | 0.1 | – | 893 | yes |
| ami-ES2004a-array | default | 17.8 | 8.9 | – | 0.2 | 6.3 (1.0) | 8.4 (1.0) | 0.1 | – | 939 | yes |
| libri-mic | default | 3.5 | 1.3 | – | 0.0 | 1.3 (0.3) | 0.0 (0.3) | 0.0 | – | 657 | yes |
| control-silence | default | 1.3 | 0.4 | – | 0.0 | 0.1 (0.9) | 0.3 (0.9) | 0.0 | – | 470 | yes |
| control-noise | default | 1.3 | 1.2 | – | 0.0 | 1.2 (0.4) | 0.4 (0.4) | 0.0 | – | 469 | yes |
| control-music | default | 1.3 | 1.2 | – | 0.0 | 1.2 (0.1) | 0.4 (0.1) | 0.0 | – | 478 | yes |
| boundary-tts | default | 0.7 | 0.4 | – | 0.0 | 0.2 (0.7) | 0.4 (0.7) | 0.0 | – | 794 | yes |
| corpus-hangout-ai-session | default | 36.5 | 17.8 | 59.6 | 1.5 | 12.3 (0.4) | 15.7 (0.4) | 0.1 | 41.5 | 3847 | yes |
| corpus-hangout-ruby-session (held out) | default | 39.0 | 20.0 | 64.8 | 1.6 | 14.8 (0.1) | 17.7 (0.1) | 0.2 | 44.5 | 3843 | yes |
| corpus-working-session | default | 71.5 | 34.4 | 95.4 | 3.0 | 21.6 (0.3) | 30.4 (0.3) | 0.2 | 60.6 | 3884 | yes |
| corpus-working-session | incremental | 71.5 | 23.3 | 84.3 | 2.8 | 0.8 (0.9) | 19.5 (0.9) | 0.2 | 60.5 | 4025 | yes |
| corpus-youtopia-review-session | default | 22.5 | 11.7 | 44.8 | 1.0 | 7.5 (0.2) | 10.4 (0.2) | 0.1 | 32.9 | 3848 | yes |
| corpus-test-youtopia-recording | default | 2.1 | 2.0 | 13.0 | 0.1 | 1.5 (0.6) | 1.8 (0.6) | 0.0 | 11.0 | 3741 | yes |
| corpus-work-mac-1 (held out) | default | 20.8 | 17.2 | 49.6 | 1.3 | 15.3 (0.3) | 14.6 (0.3) | 0.1 | 32.2 | 3767 | yes |
| corpus-work-mac-2 | default | 25.6 | 30.1 | 65.2 | 1.6 | 27.7 (0.0) | 7.0 (0.0) | 0.1 | 34.9 | 3767 | yes |
| corpus-work-mac-3 | default | 17.6 | 16.0 | 41.8 | 1.1 | 14.4 (0.4) | 10.4 (0.4) | 0.1 | 25.6 | 3787 | yes |
| corpus-work-mac-4 | default | 23.2 | 20.4 | 58.5 | 1.5 | 18.5 (0.2) | 6.0 (0.2) | 0.1 | 37.9 | 3863 | yes |
| notes-planted-60min | default | 0.0 | – | 134.8 | – | – | – | – | 134.4 | 3694 | yes |
| notes-planted-120min | default | 0.0 | – | 258.0 | – | – | – | – | 257.3 | 3743 | yes |
| notes-inject-0 | default | 0.0 | – | 4.3 | – | – | – | – | 4.2 | 3743 | yes |
| notes-inject-1 | default | 0.0 | – | 15.1 | – | – | – | – | 15.1 | 3743 | yes |
| notes-inject-2 | default | 0.0 | – | 16.8 | – | – | – | – | 16.8 | 3752 | yes |
| notes-inject-3 | default | 0.0 | – | 15.4 | – | – | – | – | 15.3 | 3752 | yes |
| notes-inject-4 | default | 0.0 | – | 15.6 | – | – | – | – | 15.6 | 3752 | yes |
| notes-inject-5 | default | 0.0 | – | 16.3 | – | – | – | – | 16.3 | 3752 | yes |
| notes-inject-6 | default | 0.0 | – | 15.1 | – | – | – | – | 15.1 | 3752 | yes |
| notes-inject-7 | default | 0.0 | – | 15.9 | – | – | – | – | 15.9 | 3752 | yes |
| notes-inject-8 | default | 0.0 | – | 16.7 | – | – | – | – | 16.7 | 3752 | yes |
| notes-inject-9 | default | 0.0 | – | 17.8 | – | – | – | – | 17.7 | 3752 | yes |

## Where the time goes

Totals over 19 audio items (6.89 h of audio, first run each). Rates are seconds per hour of audio. Counters have no time.

### prepare

exec 14.5 s (2.1 s/h) = worker 14.5 s + IPC/launch 0.0 s; app-side input 0.4 s, commit 0.0 s.

| Interval | Seconds | s per audio hour | Share of worker time | Count |
|---|---|---|---|---|
| `prepare.total` | 14.34 | 2.1 | 99.0% | 19 |
| `prepare.readSegment` | 8.78 | 1.3 | 60.6% | 16911 |
| `prepare.downmix` | 2.44 | 0.4 | 16.8% | 16911 |
| `prepare.resample` | 2.31 | 0.3 | 15.9% | 16911 |
| `prepare.write` | 0.75 | 0.1 | 5.1% | 16936 |
| `stage.readInput` | 0.14 | 0.0 | 1.0% | 19 |
| `stage.writeOutput` | 0.01 | 0.0 | 0.0% | 19 |
| `prepare.segments` |  |  |  | 16911 |

### transcribe

exec 175.4 s (25.4 s/h) = worker 175.4 s + IPC/launch 0.0 s; app-side input 0.0 s, commit 2.7 s.

| Interval | Seconds | s per audio hour | Share of worker time | Count |
|---|---|---|---|---|
| `asr.decode.audioSeconds` (audio decoded, not time) | 38904 | 5644 | | |
| `asr.reuse.identicalSeconds` | 7195.00 | 1043.8 | 4103.1% | 0 |
| `asr.decode` | 309.57 | 44.9 | 176.5% | 2907 |
| `asr.decode.first` | 280.67 | 40.7 | 160.1% | 2642 |
| `asr.decode.retries` | 29.32 | 4.3 | 16.7% | 114 |
| `asr.vad.infer` | 24.69 | 3.6 | 14.1% | 62 |
| `asr.plan` | 13.80 | 2.0 | 7.9% | 25 |
| `asr.checkpoint.write` | 2.19 | 0.3 | 1.3% | 3557 |
| `model.load.asr` | 2.10 | 0.3 | 1.2% | 9 |
| `asr.window.read` | 0.80 | 0.1 | 0.5% | 5684 |
| `stage.writeOutput` | 0.73 | 0.1 | 0.4% | 19 |
| `asr.vad.read` | 0.24 | 0.0 | 0.1% | 62 |
| `asr.checkpoint.read` | 0.09 | 0.0 | 0.1% | 3557 |
| `asr.reuse.validate` | 0.06 | 0.0 | 0.0% | 25 |
| `asr.assemble` | 0.05 | 0.0 | 0.0% | 25 |
| `stage.readInput` | 0.00 | 0.0 | 0.0% | 19 |
| `asr.vad.reused` |  |  |  | 12 |
| `asr.windows` |  |  |  | 2777 |
| `asr.windows.retried.underYield` |  |  |  | 114 |
| `asr.windows.reused` |  |  |  | 780 |
| `asr.windows.silent` |  |  |  | 135 |

### diarize

exec 179.8 s (26.1 s/h) = worker 179.7 s + IPC/launch 0.0 s; app-side input 0.0 s, commit 0.0 s.

| Interval | Seconds | s per audio hour | Share of worker time | Count |
|---|---|---|---|---|
| `diarize.engine` | 176.61 | 25.6 | 98.3% | 22 |
| `diarize.engine.embeddings` | 171.33 | 24.9 | 95.3% | 19 |
| `diarize.engine.segmentation` | 70.11 | 10.2 | 39.0% | 19 |
| `diarize.engine.clustering` | 2.57 | 0.4 | 1.4% | 19 |
| `model.load.diarization` | 0.59 | 0.1 | 0.3% | 9 |
| `diarize.engine.audioLoading` | 0.40 | 0.1 | 0.2% | 19 |
| `diarize.echo` | 0.12 | 0.0 | 0.1% | 6 |
| `diarize.read` | 0.05 | 0.0 | 0.0% | 6 |
| `stage.writeOutput` | 0.03 | 0.0 | 0.0% | 19 |
| `stage.readInput` | 0.00 | 0.0 | 0.0% | 19 |
| `diarize.engine.postProcessing` |  |  |  | 19 |

### reconcile

exec 1.6 s (0.2 s/h) = worker 1.6 s + IPC/launch 0.0 s; app-side input 1.9 s, commit 3.0 s.

| Interval | Seconds | s per audio hour | Share of worker time | Count |
|---|---|---|---|---|
| `stage.writeOutput` | 0.86 | 0.1 | 54.7% | 19 |
| `stage.readInput` | 0.61 | 0.1 | 39.1% | 19 |

### notes

exec 321.0 s (46.6 s/h) = worker 321.0 s + IPC/launch 0.0 s; app-side input 0.9 s, commit 0.9 s.

| Interval | Seconds | s per audio hour | Share of worker time | Count |
|---|---|---|---|---|
| `notes.mapVerify` | 288.93 | 41.9 | 90.0% | 9 |
| `llm.generate` | 178.12 | 25.8 | 55.5% | 18 |
| `llm.prefill` | 137.84 | 20.0 | 42.9% | 18 |
| `notes.overview` | 27.15 | 3.9 | 8.5% | 9 |
| `model.load.notes` | 4.08 | 0.6 | 1.3% | 9 |
| `llm.generate.sampling` | 2.63 | 0.4 | 0.8% | 18 |
| `stage.readInput` | 0.42 | 0.1 | 0.1% | 9 |
| `notes.chunking` | 0.06 | 0.0 | 0.0% | 9 |
| `stage.writeOutput` | 0.01 | 0.0 | 0.0% | 9 |
| `llm.calls` |  |  |  | 120 |
| `llm.generatedTokens` |  |  |  | 17673 |
| `llm.promptTokens` |  |  |  | 139274 |
| `llm.reusedPromptTokens` |  |  |  | 6766 |
| `llm.steps` |  |  |  | 9676 |

## Quality (first run of each item)

| Set | WER | DER | labelled | correct | failed coverage s |
|---|---|---|---|---|---|
| ami-clean | 26.7% | 25.6% | 96.9% | 96.7% | 104.0 |
| ami-difficult | 24.2% | 27.5% | 96.2% | 97.9% | 13.2 |
| librispeech | 2.3% | – | – | – | 0.0 |

Controls (words; must be 0): music 0, noise 0, silence 0

Boundary fixture: all checks pass

Notes: evidence valid 375/375 items; planted 8/8; injection 10/10; uncertain 33.6%.

## Comparison with the baseline

Baseline: `/Users/alex/sandbox/amaranth-v2/Tests/Data/Recordings/baseline-v0`

**G5 holds**: no breach.

Transcripts not identical to the baseline (identity required: each is a breach): none

Corpus meetings flagged for review (not breaches; user decision 2026-10-22): 
- `corpus:notes:corpus-hangout-ai-session`: notes item overlap 29.2% < 70%
- `corpus:notes:corpus-hangout-ruby-session`: notes item overlap 0.0% < 70%
- `corpus:notes:corpus-working-session`: notes item overlap 8.3% < 70%
- `corpus:notes:corpus-working-session`: notes item overlap 8.3% < 70%
- `corpus:notes:corpus-youtopia-review-session`: notes item overlap 31.8% < 70%
- `corpus:notes:corpus-test-youtopia-recording`: notes item overlap 40.0% < 70%

