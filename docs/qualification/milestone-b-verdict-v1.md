# Milestone B verdict (independent validation, 2026-10-16)

## Overall: PASS WITH CONDITIONS

The Milestone B exit statement holds on this machine: audio survives a killed or hung inference worker, a failed AI stage is not a failed recording, and recovery works as claimed. Everything I re-ran reproduced the documented numbers exactly.

The docs mostly describe the evidence honestly, and the DER shortfall and the lack of a real-call corpus are stated. The conditions are:
- one real hidden-loss path in T06;
- a few overstated or mis-cited claims;
- several acceptance items with no test.

None of the problems is architectural, and none put recorded audio at risk.

Hardware: one M2 Max (96 GB), macOS 26.5.2. Every base-M2/16 GB and 8 GB gate is **unverified**. The docs say so.

## What I ran
All scratch files are under /tmp/vb.

| Run | Result |
|---|---|
| `swift test --scratch-path /tmp/amaranth-validate-b` | 113 tests in 23 suites passed, matching the docs. Force-kill worst tail loss was 1.78 s in my run (docs: 1.27 s, earlier 1.39–1.90 s). Long test: normalized marker error 0.0 ms, raw 330 ms. |
| `amaranth-bench production-eval` (controls copied in) | Every line matches `production-eval-asr-v7.txt` exactly: WER, DER, miss/FA/conf seconds, labelled/correct, and 0 words / 0 speakers on silence, noise and music. |
| `amaranth-bench asr-sweep` | Output identical to `evidence/2026-10-16/asr-sweep.txt` (differs only by a trailing newline). The results-dir copy is content-unchanged. |
| `asr-probe` on libri-1089, 63.74–74.75 s | The defect reproduces deterministically, as documented. Context 0.3/0.3 gives 27 words; 1.0/1.0 gives 4 ("Well now, the first"); 1.5/1.5 gives 3 ("Well now, Ennis."); 2.0/1.0 gives 32. Each result was identical across two repetitions. |
| Self-tests `pipeline-e2e`, `kill-worker-while-recording`, `hung-worker-recycled` | All pass. Details are under T08. |
| Not run | `scripts/check.sh`, because its `xcodegen generate` and `xcodebuild` steps would rewrite `Amaranth.xcodeproj` and `build/`, which breaks the no-modification rule. Its `swift test` and worker fault self-tests were covered individually. The capture self-tests were not run, as instructed. |

## T05 Durable storage: MET, with overstated wording

Checked against code, the passing tests, and a re-run:
- **Force-kill recovery.**
  - `ForceKillTests` SIGKILLs a real child recorder process 5 times. Every committed file is indexed, no row points at a missing file, 0 files were quarantined, and the meeting is marked `interrupted`.
  - Tail loss was ≤ 1.78 s against the 5 s target. Loss is bounded by construction (2 s segments).
- **Recovery paths.** Lost index, missing journal, truncated file, staging salvage and torn journal each have a test that passes. The `SegmentRecovery.swift` logic matches the doc: it quarantines and never deletes, salvages whole frames only, and records the lost remainder as an explicit gap event.
- **Healthy source continues; low disk saves and deletes nothing; failed commits become explicit gaps.** Tests pass.
- **Memory and drift (2 h at 60×).** Footprint growth was −62.7 MiB in the docs run and −420 MiB in mine, so footprint noise is large. The test only asserts growth < 50 MiB. The PCM it guards against (about 1 GB at this configuration) would still be detected.

Overstated or unsupported:
1. **Drift is verified only against a synthetic clock.**
   - The 0.0 ms normalized error holds because the synthetic source's host clock is perfect and the normalizer inverts the model that generated the drift.
   - There is no timestamp jitter, so "drift < 100 ms" is not shown for real devices.
   - The doc's Limits section admits the run is synthetic and defers real hardware to T12. The table row should say "synthetic" too.
2. **Load is light.** The doc says kills happen "under replay load". The test runs 4 busy-spin threads beside a child recording a sine wave, with kills at 3–9 s (1–4 segments). It never kills during minute-shard rollover, during a long recording, or while real inference runs. The bound is still sound, but "reference load" is generous wording.
3. **Citation errors.**
   - The doc cites `RecoveryTests.randomKillsUnderLoad…`. The test is `ForceKillTests.randomKillsUnderLoad…` in `Tests/Capture/ForceKillTests.swift`.
   - `Tests/Recovery/` is an empty directory, but it is listed in the T05 `module_scope`.
4. **Callback p99 and memory gates** rest on the Milestone A 30-minute soak. I did not re-run it (it needs permissions).

## T06 ASR: MET for the engineering criteria, with one real gap and several overstated items

Verified:
- **Engine guard.** `ParakeetASR.transcribe` refuses input over 14.9 s, and a test asserts it. The long-path method `transcribeLong` still exists in the module. Production code does not call it (only the bench harness does), but nothing prevents it.
- **Window design.** Windows partition all recorded audio, VAD only picks cut points, and each word is kept by midpoint with no duplicates by construction.
- **Boundary fixture.** The `say`-generated speech uses 6 boundaries with 8 s windows. All 8 date/number facts survive, negation counts match, no adjacent duplicates, first and last words match. WER was 4.7% and 8.1%. This is one synthetic voice, and the default policy test only exercises about 2 boundaries.
- **Controls.** Silence, noise and music give 0 words in `production-eval` and in `silenceAndToneProduceNoWords`.
- **Defect 1 (chunk drops above 15 s)** is plausible: the sweep shows the long-path reference differs from the chunked path. I did not re-run the 23.5/24.0/24.5 s measurement. The tests that cover the guard do pass.
- **Defect 2** is reproduced, as above.
- **Public-only labelling.** The docs are honest. `asr/0001` says plan §10 is measured on public data only and that AMI is not the held-out real-call corpus. It does not claim the §10 gates are met.

Unmet, overstated or unsupported:
1. **Residual lost speech is not surfaced.**
   - After the retries, `WindowResult.uncoveredSpeech` is written only to the checkpoint JSON. Nothing sets a coverage status or word flag from it.
   - `coverage()` labels the whole window `transcribed`.
   - The chosen policy's own sweep shows the effect: ES2004a 22 s of VAD speech uncovered, IS1009a 23 s (2 windows still under-yield), EN2002a 112 s (12 windows), far-field 24 s (1 window), plus 2 s on LibriSpeech.
   - Some of that is crosstalk or VAD false positives, but the pipeline cannot tell. The doc says it is "recorded per window", which is technically true and effectively hidden.
   - The tasks.json criterion says unknown coverage is "never silently omitted", and this is a silent omission path. It cannot invent text, but it can hide losses.
2. **The guard is blind to speech that VAD misses.** Detection compares ASR output against VAD speech only.
3. **Retry acceptance is loose.** When the original decode is `questionable`, any non-empty non-garbled alternative replaces it even if its coverage is worse, and the `questionable` flag is then cleared.
4. **Cancel/restart test.**
   - The doc says "identical text without re-running checkpointed windows". The test compares the resumed run with a second run that loads all checkpoints. It never compares against an uninterrupted from-scratch run.
   - It does not assert that completed windows were not re-decoded. It only asserts `checkpointed >= 3`.
   - The code does skip existing checkpoint files, so the behaviour is probably right, but the assertion is missing.
5. **Selection and overfitting.**
   - The window policy and the guard thresholds (2.0 s, 0.6 s) were tuned on the same four AMI recordings used to report results.
   - "2 s everywhere" wins on 3 of the 5 columns but loses far-field (24.0 vs 23.1) and LibriSpeech (1.0 vs 0.8) to another policy.
   - The "non-overlap 13.9%" figure covers only 1,312 reference words in segments of at least 1 s with no overlap, so it is thin and biased easy. `models/0001` calls the same samples "thin".
   - Plan §10 asks for ≤ 15% on held-out real calls. All-words WER is 26.5%, which is not a pass. The doc's explanation that overlap dominates the difference is plausible but not demonstrated.
6. **Contradiction between docs.** `models/0001` line 44 still says "Per-window analysis found no dropped chunks", while `asr/0001` says the same long path drops chunks. Tracked item 13 admits the re-score is pending, but the models doc itself is not annotated.
7. **Minor.** The meeting-length range "17–36 min" is actually 14–36 min (IS1009a is 839 s). Earlier version rows (v1, v6) are not reproducible from the shipped evidence. Language ID is not implemented, which the doc admits.

## T07 Diarization and attribution: PASS WITH CONDITIONS (DER gate not met, honestly stated)

Verified:
- **DER** reproduces exactly: 22.2%, 23.1% and 27.6% on clean AMI against a gate of ≤ 20% (**not met**), and 27.6% on far-field against ≤ 30% (met on this AMI recording). The scorer is no-collar, scores overlap, uses an optimal one-to-one mapping and counts unknown as missed.
- **Attribution computation** (`Benchmarks/Harness/main.swift`, `productionEval`) is sound, with these caveats:
  - "Labelled" is the share of **ASR-emitted words** whose midpoint falls in single-reference-speaker speech and that received a speaker. It is not the share of reference speech time. ASR deletions are therefore not penalized in it.
  - "Correct" has a **denominator of labelled words**, which is what §10 asks for ("among assigned words"). Words whose cluster has no DER mapping count as wrong, which is conservative.
  - The docs do not state these definitions.
  - So "attribution met (96.9% / 96.8%)" is true on this proxy and on AMI headset mixes only. It is not the §10 held-out measure.
- **No names invented.** The reconciler only produces "Speaker N" labels, and `eightSpeaker…` plus `attributesByIntersection…` pass. Uncertain candidates are kept on words (`.multiple`, `uncertainSpeaker`, `.unknown`).
- **Echo handling** flags words reversibly and never removes them. The test confirms a genuine interruption and an isolated common word survive. It uses idealized synthetic timing.
- **Edits.** Rebase by word identity or time-plus-text, with `needsReview` on ambiguity. The scheduler tests for stale edits pass.
- **Memory.** `diar-memory.txt` supports "flat": 1098 MiB at 2 h and 1076 MiB at 4 h with 30-minute blocks, against 1175 and 1267 MiB full-file. This is a synthetic concatenation, a single run, and a streaming harness (not through the worker).

Unmet or unsupported:
1. **`EchoAnalyzer`, which measures acoustic delay, has no test and no measurement evidence.** The task lists "measure acoustic delay, cross-source duplicates" as a deliverable. Nothing in `Tests/`, the self-tests or the benchmarks exercises it. `pipeline-e2e` uses separate synthetic sources with no bleed. The estimator also scans only the first 10 minutes, searches lags of 0–500 ms, and returns a single global delay. The reconciler's ±0.25 s word match could miss real echo, which fails safe (duplicates are kept).
2. **Cross-block over-splitting.** 11 clusters against 8 on the 2 h and 4 h concatenations. This is tracked (#11) and only affects meetings over 1 h. DER on long concatenations was not measured.
3. **`SourceMap(epochs: [], events: [])` is passed in production reconcile** (`StageRunner`). I could not find a use of it in `MeetingReconciler.combine`, so it is currently harmless, but it signals unfinished wiring.
4. **SpeakerKit fallback not yet evaluated.** The task fallback was to "evaluate SpeakerKit or improve clustering". The status line in tasks.json states this honestly.

## T08 Orchestration: MET, with test gaps

Verified:
- **Kill the worker while recording (reproduced).**
  - I ran `kill-worker-while-recording`: the real XPC worker was SIGKILLed at 16% of transcribing meeting A while meeting B recorded.
  - Meeting B had 31 segments after the kill, was contiguous with 0 missing-audio events, and transcribe succeeded on attempt 2.
  - `hung-worker-recycled`: the worker PID changed (3340 to 3374), prepare ran 2 attempts, and the pipeline completed. It uses an 8 s hang timeout, against a production default of 300 s.
  - `pipeline-e2e`: all four stages succeed, 4 speakers, mic WER 1.2%. My run differed slightly from the stored evidence (unknown words 3 vs 5; segments 194 vs 196), which is normal replay jitter.
- **No inference in the capture process (structural proof).** The app target links no ASR, Diarization, FluidAudio or ProcessingRuntime module. `nm` finds none of `StageRunner`, `ParakeetASR`, `TranscriptionPipeline` or `FluidDiarizer` in the app binary or its dylib. The symbol `StageRunner` is present in the XPC worker (43 matches).
- **Scheduler tests.**
  - One heavy stage at a time: the loop is fully serial.
  - Relaunch requeue, deletion tombstone (late results refused, publication guarded atomically), stale-edit discard and recompute, idempotent enqueue and `INSERT OR REPLACE` edits all have passing tests.
  - The "second meeting with a failed prior stage" test uses a simulated failed diarize, not a failed summary. The doc says so.
- **Fault injection** is compiled out of release builds (`#if DEBUG`).

Gaps and overstatements:
1. **Suspension is under-tested.**
   - Only the queued-job case under a `recording` pressure box is tested.
   - No test covers a heavy stage that is already running when a recording starts (the watchdog cancel then suspend path).
   - Thermal and memory pressure wiring (`ProcessingModel`) has no test at all.
   - So "react to thermal/memory pressure" is implemented but unverified.
2. **Diarization is neither cancellable nor heartbeat-visible mid-call for meetings under 1 hour.**
   - `FluidDiarizer.analyze` makes a single `manager.process(url)` call, and progress is reported only between sources.
   - Consequences: a recording that starts mid-diarize does not interrupt it until it finishes (tens of seconds on the M2 Max). On slower hardware, a legitimately long call risks tripping the 300 s hang watchdog, which then kills a healthy worker and retries up to 3 times.
   - This is unverified on base-M2 hardware.
3. **The doc says "light stages may run alongside".** The loop is strictly serial and runs nothing concurrently. This is harmless, but it describes behaviour that does not exist.
4. **The stale check fails open.** If `input.json` cannot be re-read, `usedEdit` falls back to `latestEdit`, which treats the result as fresh.
5. The kill test deliberately disables pressure suspension. In production, a stage already running when recording starts is cancelled rather than killed. The doc is upfront about this.

## Known gaps: acceptable or not?

| Gap | Judgment |
|---|---|
| DER above gate on clean AMI (22–28% vs ≤ 20%) | **Acceptable deferral** to release. It is honestly labelled, tracked (#4) as a release blocker, and has a stated next step (SpeakerKit head-to-head). Milestone C must not display speaker attribution as reliable in overlap-heavy meetings. |
| No real-call corpus | **Acceptable deferral** (user-owned, #9). It is the reason every quality gate is public-data-only. No §10 held-out gate is claimed as met anywhere I read. |
| No language ID | **Acceptable deferral**. v0 is English. The UI in C must not imply language was checked. |
| Blockwise over-splitting on meetings over 1 h | **Acceptable deferral** (T07, #11). |
| Offline check of the XPC worker | **Acceptable deferral** to T12. The code path is verified under `sandbox-exec (deny network*)`, `offlineMode = true` is set on all three engines, and the app has no network code. The launchd-started worker itself is untested. |

## Required before Milestone C (prioritized)
1. **Surface residual uncovered speech** (T06). Carry `uncoveredSpeech` and the retry outcome into transcript coverage or word flags, so that notes and the UI never present an under-yielded window as fully transcribed.
2. **Add the missing tests or assertions:**
   - a unit test for `EchoAnalyzer` using a synthetic delayed copy;
   - a resume-equals-uninterrupted-run assertion, and an assertion that checkpointed windows are not re-decoded;
   - a scheduler test for a running heavy stage when recording starts;
   - thermal and memory pressure tests.
3. **Fix the diarization hang and cancel exposure** (T08/T07). Add progress or cancellation inside the diarization call, or scale the hang timeout with audio length, so that slow hardware does not trigger false recycles.
4. **Correct the documents:**
   - the test name and path in `storage/0001`;
   - the "replay load" wording;
   - the "light stages alongside" claim;
   - the "no dropped chunks" line in `models/0001`;
   - state the attribution metric definitions in `diarization/0001`;
   - add the thin-sample and in-sample-tuning caveats to `asr/0001`.

## Acceptable deferrals (with owners)
- T12: real two-hour hardware capture and real-device drift; a network-denied worker run; base-M2/16 GB and M2/8 GB qualification (#8).
- T07: DER on clean AMI and the SpeakerKit comparison (#4); long-meeting identity linking (#11).
- T06: language ID (#10); re-score the T02 challengers with the production pipeline (#13).
- T08/T04: Core ML warm-up in the installer (#3).
- User: real-call corpus (#9) and permission to file the upstream FluidAudio defects (#12).
- Not independently verified by me: the 23.5/24.0/24.5 s chunk-drop measurements, and the Milestone A soak p99 figures.
