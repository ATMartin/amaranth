# Processing 0002: Transcription and diarization run concurrently (T17)

Date: 2026-10-22 · Task: T17 (docs/milestone-e-performance-plan.md) · Status: Accepted (user decision 2026-10-22).
Amends processing/0001 "Concurrency" and plan §10 "one heavy stage at a time".

## Context

T16 (docs/qualification/milestone-e-t16-breakdown.md) found that, on Release, a 60-minute two-source meeting reached its
transcript in 105 s against the G1 target of ≤ 60 s. Two causes:
- the worker ran one job at a time, so diarization (20 s) waited for both sources to be transcribed (82 s);
- transcription decoded its 913 windows one after another on one Parakeet instance.

## Measurements (`amaranth-bench asr-concurrency`, M2 Max, Release)

On ES2004a, 1,000 s, 13 s windows:

| Configuration | Wall | Speed-up | Output |
|---|---|---|---|
| 1 decoder | 6.51 s | 1.00× | reference |
| 2 decoders | 4.12 s | 1.58× | identical |
| 3 decoders | 2.87 s | 2.27× | identical |
| 4 decoders | 2.82 s | 2.31× | identical |
| 5 decoders | 2.87 s | 2.27× | identical |

- Each extra decoder adds about 5 MiB: instances share the compiled Core ML models.
- **Decode cost per call does not depend on window length** (80–100 ms from 5 s to 14.9 s). FluidAudio pads every
  input to its fixed 15 s encoder shape.
- Encoder on GPU or CPU gives different words in 13–15% of windows and is not faster. Not used.
- Diarization concurrent with one decoder: 7.4 s wall against 12.2 s run back to back.

## Decision

1. **Scheduler** (`JobScheduler`): `transcribe` and `diarize` may run at the same time, one of each. Every other stage
   (prepare, reconcile, notes) still runs alone. Among queued jobs, the oldest one that may run beside the active
   jobs starts. `Configuration.concurrentAnalysis` (default on) controls this.
2. **Rollback:** Settings → Recording → "Find speakers while transcribing" (`concurrentAnalysis` user default). Off
   restores strictly one stage at a time. Takes effect at the next launch.
3. **Worker models** (`ModelProvider`): ASR and the diarizer stay resident together. The notes LLM is still exclusive:
   loading it releases both, and loading either releases it.
4. **Transcription** (`TranscriptionPipeline`): the windows of all sources form one queue, drained by a pool of
   Parakeet instances (`decoderCount`, default 2). VAD chunks are spread over 2 VAD instances. Each window is decoded
   from a fresh decoder state with the same contexts and under-yield guard, so the transcript is byte-identical to
   the serial pipeline (test `concurrentDecodersGiveTheSameTranscriptAsOne`; perf-suite `--require-identical`).
5. **Warm-up at install** (tracked item 3): after a pack installs and verifies, the app sends `WorkerRequest.warmUp`. The
   worker loads the ASR pool and the diarizer, so Core ML compiles them for this Mac before the first meeting.

## Results (perf-suite, Release, against the frozen v0 baseline)

Run `Benchmarks/Results/2026-10-22-perf-t17b/` (final configuration, 2 decoders): `--compare baseline-v0
--require-identical` passes. **All transcripts and notes are identical to v0**, with 0 G5 breaches and 0 corpus flags.

| Item (seconds after Stop) | v0 (R2c) | T17, 3 decoders (t17a) | **T17, 2 decoders (t17b)** |
|---|---|---|---|
| timing-2src-60min, transcript with speakers (cold / warm) | 104.9 / 103.7 | 54.9 / 55.3 | **53.8 / 53.1** |
| of which transcribe / diarize exec (cold) | 81.2 / 20.0 + 82.7 queued | 40.6 / 51.7 | 50.0 / 45.1 |
| corpus-working-session (72 min, one source) | 63.1 | 42.6 | **40.5** |
| ami-EN2002a-mix (36 min) | 43.9 | 25.5 | **23.6** |
| timing-2src-60min, notes (cold / warm) | 251.8 / 248.3 | 219.0 / 244.6 | 206.0 / 251.5 |

- **G1 met: 53–54 s for 60 minutes (target ≤ 60 s). G3 is met by the same path.**
- **Choosing the decoder count:** the two stages share the Neural Engine, so diarization slows down as ASR gets more
  decoders. The meeting ends at the later of the two:

  | Decoders | Transcript (cold / warm) | Transcribe | Diarize |
  |---|---|---|---|
  | 2 | 53.8 / 53.1 s | 50.0 s | 45.1 s |
  | 3 | 54.9 / 55.3 s | 40.6 s | 51.7 s |
  | 4 | 58.7 / 58.2 s | 38.5 s | 55.5 s |

  Sources: `…-perf-t17-dec2/`, `…-perf-t17a/`, `…-perf-t17-dec4/`. With 2 decoders the stages are balanced, and on
  single-source meetings diarization is the longer stage anyway.
- The Neural Engine is now close to saturated during analysis. Further G1 gains need less work, not more overlap:
  - fewer or shorter contexts (a G5 trade);
  - a cheaper retry rule;
  - doing the work during the meeting (T19).
- G2 (notes) is unchanged by T17. 206–252 s still leaves a thin margin (T18).

## Memory and thermal

- **Peak worker footprint** with transcription and diarization overlapping: 0.87–1.03 GiB on the audio-only items,
  against 0.71–0.85 GiB in v0. The overall peak is still the notes stage (1.4–1.5 GiB, unchanged).
- **Thermal state** (`timing.json`, 111 stage records per run):
  - T17: "fair" at 109 starts and 108 ends;
  - v0: "fair" at 41 starts and 45 ends.

  It never reached "serious", the level at which the scheduler suspends heavy work. Analysis is denser, so the Mac
  runs warmer, but for less time. The scheduler's thermal and memory back-off is unchanged and still applies to both
  stages. On a slower or fanless Mac, the rollback setting restores serial processing.

## Limits

- If the hang watchdog kills the worker, both concurrent jobs fail as "worker lost" and are retried (same policy as
  before, now for two jobs).
- Notes still wait for any running transcription or diarization, and vice versa. Notes priority and preemption are
  T18.
- Debug builds: optimising only the third-party Swift packages (FluidAudio) in Debug is not possible with Xcode's
  package integration. It is all targets or none, and the user wants Amaranth's own code to stay debuggable in Debug.
  Release builds are fully optimised. Not done.
- Base M2 / 16 GB: unverified (no hardware). The pool's extra memory is small, but Neural Engine contention may
  differ.
