# T16: where the time goes (the 7× and 12× gaps)

Date: 2026-10-22 · M2 Max, macOS 27.0.1 (26A434), AC power · Task T16 (docs/milestone-e-performance-plan.md)

All numbers come from `amaranth-bench perf-suite`. It replays audio through the real capture path, the app's
`JobScheduler` and the XPC worker. The instrumentation is described below. Reports hold metrics and IDs only.

| Run | Build | Results |
|---|---|---|
| D1: full suite | Debug | `Benchmarks/Results/2026-10-22-perf-d1-debug/` |
| D2: two-source 60-min item | Debug | `Benchmarks/Results/2026-10-22-perf-d2-debug-timing/` |
| R1b, R2b: full suite, twice | Release | `Benchmarks/Results/2026-10-22-perf-r1b-release/`, `…-r2b-release/` |
| R2c: full suite after the determinism fixes: **the frozen v0 baseline** | Release | `Benchmarks/Results/2026-10-22-perf-r2c-release/` |
| R3: full suite on the same cached captures: noise run and `--compare` check | Release | `Benchmarks/Results/2026-10-22-perf-r3-release/` |

The plan's "today" column comes from `evidence/2026-10-16/processing-timing-60min.json`. It is the two-source
60-minute meeting that `timing-2src-60min` rebuilds (same sources, same lengths).

## Summary

1. **The 2026-10-16 timings were measured on a Debug build.** D2 reproduces them stage by stage on Debug. On a Release
   build, the same meeting gives its transcript in **105 s instead of 589 s**, and notes in **259 s**.
2. **The "12×" diarization gap is not diarization.**
   - Of the 255 s, 183 s is time queued behind transcription (the worker runs one job at a time), and about 3.6× of
     the rest is the Debug build.
   - In Release, diarizing 60 minutes takes **20 s**, the same as the isolated measurement (21 s).
3. **The "7×" transcription gap is about 2× Debug build and about 3.3× production windowing.**
   - The isolated figure (RTF 0.0035, models/0001) comes from FluidAudio's long-audio path. That path drops chunks
     (tracked items 12 and 13) and decodes less audio.
   - The production design in asr/0001 decodes single-pass windows with 2 s of context, re-decodes windows that lose
     words, and runs VAD first. asr/0001 already reports RTF ≈ 0.01 for that design; Release measures 0.0114 here.
   - In-process and worker runs agree: ES2004a ASR takes 11.0 s in-process and 11.1 s in the worker (`evidence/2026-10-16/production-eval-asr-v8.txt`
     and R1b). So **XPC, the worker and the scheduler add no measurable time.**
4. **The remaining G1 miss is structural.** Even in Release:
   - transcription of the two sources takes 82 s for 60 minutes;
   - diarization (20 s) waits for all of it;
   - so the transcript arrives at 105 s against a 60 s target.

   Notes meet G2 on Release (259 s, target ≤ 300 s), with little margin.

## The 60-minute two-source meeting, stage by stage

Seconds after Stop. *exec* is the worker round trip; *queued* is time waiting for the worker.

| Stage | 2026-10-16 evidence | D2 Debug (cold) | R1b Release (cold) | R1b Release (warm) | Isolated (models/0001, asr/0001) |
|---|---|---|---|---|---|
| Prepare (resample both sources) | 35 | 34.6 | 0.6 | 1.5 | – |
| Transcribe (both sources) | 177 | 181.7 | 82.2 | 80.3 | 25 (long path, RTF 0.0035); ≈ 72 at production RTF 0.01 |
| Diarize (system source), exec + queued | 255 | 73.1 + 183.3 | 20.2 + 83.1 | 19.9 + 81.4 | 21 |
| Reconcile | 2 | 0.9 | 0.3 | 0.3 | – |
| **Stop → transcript with speakers** | **≈ 470** | **292** | **105** | **104** | |
| Notes | 297 | 276.8 | 153.3 | 148.9 | 200–204 (`notes-eval`, 60 min) |
| **Stop → notes** | **589** | **570** | **259** | **253** | |

Run to run, Stop → transcript stays within ±2 s: 104–107 s in R1b, R2b, R2c and R3.

Stop → notes varies more, from 246 s to 297 s across those runs, so G2's margin is thin. Even with identical inputs and
identical notes output (R2c compared with R3), the notes stage's wall time varied by about 8%.

The plan's "~470 s to transcript" counted the whole diarize row as diarization time. The worker log shows it was
mostly queueing: 35 + 177 + 78 + 2 ≈ 292 s, and D2 gives the same 292 s.

## Why Debug is so much slower

The Xcode Debug configuration builds the app, the worker **and the Swift packages** (FluidAudio, our DSP and grammar
code) without optimisation. Core ML and llama.cpp (Metal) are prebuilt, so model inference itself barely changes. The
Swift code around it does change.

| Sub-stage (full suite except the timing meeting: 4.4 h of audio plus 12 notes fixtures) | D1 Debug | R1b Release | Ratio | Where |
|---|---|---|---|---|
| `prepare.downmix` | 241.6 s | 1.7 s | 140× | per-sample Swift loop |
| `prepare.readSegment` | 129.5 s | 2.9 s | 45× | CAF decode + conversion |
| `asr.window.read` | 92.3 s | 0.4 s | 230× | sample copy per window |
| `asr.vad.read` | 39.3 s | 0.1 s | 390× | |
| `asr.decode` (Core ML + FluidAudio feature/TDT loop) | 204.6 s | 155.3 s | 1.3× | the TDT greedy loop is Swift |
| `diarize.engine` | 250.1 s | 82.1 s | 3.0× | FluidAudio embedding/segmentation pre- and post-processing |
| `llm.generate.sampling` (grammar + argmax per token) | 952.3 s | 9.9 s | 96× | `LlamaRunner` grammar walk |
| `llm.generate` excluding sampling | 941.4 s | 1013.2 s | 0.9× | Metal, prebuilt |
| `llm.prefill` | 238.2 s | 269.8 s | 0.9× | Metal, prebuilt |

The user's first real meeting (2 minutes, Debug app) took about 18 s to transcript and about 45 s to notes. The same
meeting in the corpus (`corpus-test-youtopia-recording`) takes 3.4 s and 17.1 s on Release.

**Consequence for T17:** the app the user runs must be a Release (optimised) build. The development build can also
compile the hot Swift packages with optimisation. This is the largest single lever and needs no change to any model or
output. On identical committed audio (the Amaranth-recorded meeting), the Debug and Release ASR outputs are identical
(same canonical hash in D1 and R1b).

## Transcription on Release (82 s for 2 × 60 min)

From the `timing-2src-60min` trace (R1b cold):

| Interval | Seconds | Note |
|---|---|---|
| `asr.decode` (all Core ML decode calls) | 75.2 | 913 calls over **11,860 s of audio for 7,200 s recorded (1.65×)** |
| of which first pass (`asr.decode.first`) | 65.4 | 787 windows |
| of which under-yield retries (`asr.decode.retries`) | 10.0 | 52 windows re-decoded (asr/0001 guard) |
| `asr.plan` (includes VAD inference 5.6 s) | 5.6 | |
| `asr.checkpoint.write` | 0.6 | 792 fsyncs |
| window reads, model load, assembly | < 0.5 | |

- **Context overhead, 1.65×.** Each window is decoded with 2 s of context on both sides: 4,660 s of extra audio.
- **Per-second decode cost, 1.8×.** 75.2 s / 11,860 s ≈ 0.0063 s per decoded second, against 0.0035 on the long path.
  The per-call cost is about 82 ms for windows averaging 13 s. A likely cause, not yet verified, is that the encoder
  has a fixed 15 s input shape, so a shorter window costs as much as a full one. T17 should measure cost against
  window length before relying on this.
- **Retries:** 10 s, about 12% of transcription time.
- **VAD:** 5.6 s.

T17 levers this points at, all within G5:
- overlap transcription and diarization (they're independent, and diarize currently waits 81–83 s);
- fewer or shorter contexts;
- fuller windows (fewer calls);
- batching the two sources;
- a cheaper retry rule.

## Diarization on Release (20 s for 60 min)

| Interval | Seconds |
|---|---|
| `diarize.engine` | 20.1 |
| `diarize.engine.embeddings` (FluidAudio timing) | 19.1 |
| `diarize.engine.segmentation` (FluidAudio timing, overlaps embeddings) | 9.1 |
| `diarize.engine.clustering` | 0.6 |

This matches the isolated 21 s. The cost is the queue: diarize starts only after both sources are transcribed.

## Notes on Release (153 s for 60 min)

40 llama.cpp calls:

| Part | Seconds | Share |
|---|---|---|
| `llm.generate` | 118.2 | 77% |
| `llm.prefill` | 34.2 | 22% |
| Grammar sampling | 1.2 | 1% |

- Over the R1b audio meetings (6 notes jobs, 115 calls): 142,639 prompt tokens (28,296 of them reused from the KV cache)
  and 22,465 generated tokens.
- **Notes are generation-bound.** The T18 levers that cut generated tokens come first: batched verification, terser
  output, and earlier item caps.
- Model load is 0.4 s; the notes model stays resident between jobs.

## Other findings

- **Prepare** costs 0.6–2.4 s per meeting on Release. It is not worth optimising beyond T19's incremental derivative.
- **Scheduler and IPC:** app-side input writing, commit and IPC overhead sum to about 9 s over the 5.4 h of audio in R1b
  (under 2 s per audio hour). The
  wait from Stop to the first job starting is under 1 s.
- **QoS:** every stage ran at `userInitiated`. Thermal state moved between nominal and fair during long stages in
  both Debug and Release, never higher.
- **Memory:** peak worker footprint was 1.5 GiB (notes); transcription and diarization stayed under 0.9 GiB.
- **Real meetings have two sources; the corpus has one.** Corpus meetings are all mixed single-track recordings, so
  only one source is transcribed. The 72-minute corpus meeting meets G1 on Release (64 s), but the two-source
  `timing-2src-60min` doesn't (105 s). G1 and G2 are judged on items of at least 50 minutes, scaled to 60 minutes.

## Determinism (needed for "pure refactors are byte-identical")

Comparing R1b with R2b showed every replayed item's transcript differing between runs. Three causes were found and
fixed before freezing v0:

1. **Capture replay timing.**
   - Each replay starts a few microseconds later on the host clock and ends with a variable amount of trailing
     silence. That shifts every timestamp and changes the window plan.
   - perf-suite now replays each audio item **once** into a persistent capture cache
     (`Tests/Data/Recordings/.perf-cache/captures`). Later runs process copies of the same committed capture.
   - Amaranth-recorded meetings were already copied rather than replayed, and were already identical across runs.
2. **Reconciler ties (production bug).**
   - `MeetingReconciler` ranked candidate speakers by sorting a `Dictionary` by score. Swift's dictionary order is
     seeded per process.
   - Words fully covered by two turns, which are tied, got a different speaker, or a different `.multiple` order,
     on each run. In R1b, the timing item's cold and warm runs processed copies of the same capture. Of their 13,938
     words, 342 had their `.multiple` speakers in a different order, and 2 had a different speaker.
   - Ties now follow first-seen order (`tiesAreBrokenDeterministically`).
3. **Notes reduce order (production bug).**
   - Items with the same first line but different kinds kept per-process dictionary order.
   - That changed the overview prompt, and with it the overview text (`notes-planted-60min`).
   - Ties are now ordered by kind.

Result after the fixes: **R3 against the R2c baseline gives identical canonical transcripts for all 28 item runs
(`--require-identical` passes) and identical notes** (text, items and evidence counts). Only per-run IDs differ.

The capture cache is keyed by the SHA-256 of each raw input, because perf-suite rewrites the inputs on every run.

Validation of the harness itself:
- `perf-suite score R3 --compare baseline-v0` exits 0: G5 holds, and no corpus meeting is flagged.
- The same comparison with `--inject-regression` exits 1, with WER, control, boundary and notes-evidence breaches.

## Instrumentation (what T16 added)

- **Worker:** `os_signpost` intervals (subsystem `com.alexmartin.amaranth`, category `pipeline`) and a task-local
  `PerfTrace`. They cover:
  - prepare: read, downmix, resample, write;
  - ASR: plan, VAD read/infer, window read, decode first and retries, checkpoints, assemble;
  - diarization: engine, FluidAudio's own `PipelineTimings`, echo;
  - notes: chunking, extract, verify, overview, and per-call prefill, generation, sampling and token counts;
  - model loads.

  Each stage writes `timing.json` next to its output, with its build configuration, QoS and thermal state.
- **Scheduler:** `timing-scheduler.json` per job: queued, started and finished times, input writing, execute and
  commit.
- **FluidAudio:** segmentation and embedding times come from FluidAudio's `PipelineTimings`; they overlap, so they
  aren't additive. The Core ML calls inside the TDT decoder can't be split further without modifying FluidAudio; they
  are measured from the outside as `asr.decode`. This is the fallback the task allows.
