# Milestone B verdict v2 (re-validation after the changes in milestone-b-changes-after-verdict-v1.md)

## Overall: PASS

All four required fixes from v1 are in place and hold up under adversarial checking. I found no regressions. Only minor, non-blocking observations remain, and all of them can wait.

## What I ran
Scratch files are under /tmp/vb. I did not modify any source or docs, did not touch `build/` or `Amaranth.xcodeproj`, and did not run the capture self-tests.

| Run | Result |
|---|---|
| `swift build -c release --product amaranth-bench` | Complete. |
| `swift test --scratch-path /tmp/amaranth-validate-b` | **122 tests in 26 suites passed**, which matches the changes doc (previously 113). |
| `amaranth-bench production-eval` into /tmp (controls copied in) | Output is identical to `evidence/2026-10-16/production-eval-asr-v8.txt` apart from timings and a trailing newline. WER, DER and attribution are unchanged from v7: 26.5% / 13.9% / 96.9% / 96.8%. Failed coverage: 7 regions / 11 s, 9 / 16 s, 39 / 72 s and 11 / 16 s. Controls give 0 words and 0 speakers. |
| Self-tests `pipeline-e2e`, `hung-worker-recycled`, `kill-worker-while-recording` | All pass. The worker PID changed on the hang test (9762 to 9790). The kill test again shows meeting B contiguous and the transcribe stage retried. |

## Fix-by-fix

1. **Residual uncovered speech is surfaced (T06): FIXED.**
   - `coverage()` now emits `failed` regions for VAD speech that still has no words after the retries, in stretches of 1 s or more. The emitted regions are ordered and non-overlapping.
   - Regression check on tiling: failed intervals come from each window's own clipped speech, so they cannot cross a window boundary. The `emit` loop advances a cursor (`t = max(t, fb)`), so overlapping failed intervals cannot double-count.
   - `untranscribedSpeechIsReportedAsFailedCoverage` asserts the failed interval is exactly [4.2, 11.5], that the total coverage equals the window length (no overlap and no gap), and that misses under 1 s are not reported.
   - The numbers it produces on real audio are plausible, and they are consistent with the sweep's uncovered seconds in v1 (112 s uncovered against 72 s failed on EN2002a).
   - Observations, not blockers:
     - The only tiling test is single-window. `TranscriptRevision.validate()` does not check that coverage regions do not overlap, so tiling holds by construction and by that one test.
     - The 1 s threshold and the 0.6 s padding are unchanged, so the guard remains blind to speech that VAD misses. This is now tracked as #14.
     - Nothing downstream consumes `failed` yet. The notes and UI in Milestone C must render it.

2. **Missing tests: FIXED.**
   - `EchoAnalyzerTests` exist (60, 180 and 350 ms delays with a local talker present, unrelated audio giving nil, short audio giving nil).
   - The resume test now checks checkpoint modification times and equality with an uninterrupted fresh run.
   - The scheduler tests `runningHeavyStageYieldsWhenRecordingStartsAndResumesAfter` and `thermalAndMemoryPressureSuspendHeavyStages` exist and pass.
   - The pressure policy was extracted to `JobScheduler.Pressure.current(...)` and is used by `ProcessingModel`.
   - I did not re-derive the 0.41–0.45 s cancel time. The test passed in my run under its own assertions.

3. **Diarization hang and cancel exposure: FIXED.**
   - `EngineCall.run` wraps both the full-file call and each block call.
   - Cancellation: the monitor cancels the work task, `withTaskCancellationHandler` forwards cancels, and there is a post-completion `cancellation.check()`.
   - Liveness: ticks go out every 5 s within a budget of max(120 s, 10% of audio length). After the budget they stop, so a truly hung call is still detected by the 300 s watchdog.
   - Wiring is confirmed in `StageRunner`: the trailing closure passes ticks to `progress(...)`.
   - Tests pass, including the real-model mid-meeting cancel.
   - One semantic to know about: a post-completion `cancellation.check()` discards a finished result when a cancel arrives in the same instant. That is safe, because the stage is retried or resumed.

4. **Document corrections: FIXED.** Spot-checked the changes list against the files. The long-path rename (`benchmarkOnlyTranscribeLong`) and the guard test `productionCodeNeverUsesTheChunkDroppingLongPath` are present and passing. The empty `Tests/Recovery/` is gone.

## Other changes checked
- **Stale-edit check now fails closed.** An unreadable reconcile input throws `JobFailure.permanent("reconcile.inputUnreadable")`. This sits inside the `do/catch` in `run`, so it becomes a permanent job failure and nothing is published, while the earlier ASR revision stays visible. The cost is that the user must retry. That is the correct tradeoff. No regression found in the stale-edit path.
- The `check.sh` claim (ALL AUTOMATED CHECKS PASSED) is consistent with the 122 tests and the self-tests I ran. I did not run `check.sh` itself, for the same reason as in v1.

## Still open from v1 (acceptable, with owners)
- Residual under-yield is now visible but still only measured on VAD-detected speech (#14).
- Drift and force-kill remain synthetic or light-load (#16, T12).
- `SourceMap` is unwired in production reconcile (#15).
- DER on clean AMI above gate, SpeakerKit comparison (T07, #4), blockwise over-splitting (#11), language ID (#10).
- Offline check of the launched worker (T12), base-M2 gates, real-call corpus (user).
- Suggested, low priority: a multi-window coverage-tiling test, or a tiling check in `validate()`, before the C-phase UI relies on coverage.

## Required before Milestone C
None.
