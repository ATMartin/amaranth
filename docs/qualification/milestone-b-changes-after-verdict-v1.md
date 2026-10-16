# Milestone B: changes made in response to validator verdict v1 (PASS WITH CONDITIONS)

## Required fixes

1. **Surface residual uncovered speech (T06).**
   - VAD speech still without words after retries, in stretches of 1 s or more, is now a `failed` coverage region,
     never `transcribed`. Code: `TranscriptionPipeline.coverage` and `uncoveredIntervals`.
   - The contract comment on `CoverageRegion.Status.failed` documents this use.
   - The pipeline version is bumped to `asr-pipeline-v8`, with matching app and self-test hashes and producer
     `configHash`.
   - Unit test: `untranscribedSpeechIsReportedAsFailedCoverage`.
   - production-eval now prints the failed seconds per meeting: 11 / 16 / 72 / 16 s. Evidence:
     `evidence/2026-10-16/production-eval-asr-v8.txt`, re-run offline in `production-eval-offline-sandbox.txt`.
2. **Missing tests and assertions.**
   - `EchoAnalyzer`: `Tests/Diarization/EchoAnalyzerTests.swift`, covering 60, 180 and 350 ms delays with a local
     talker present, unrelated audio giving nil, and short audio giving nil.
   - Resume: checkpoint modification times stay unchanged across resume (not re-decoded), and the resumed transcript
     (words and coverage) equals an uninterrupted fresh run.
   - Scheduler: `runningHeavyStageYieldsWhenRecordingStartsAndResumesAfter`, plus
     `thermalAndMemoryPressureSuspendHeavyStages` (thermal and memory cases).
   - `pressurePolicyMapsAppSignals`: the app's policy was extracted to `JobScheduler.Pressure.current(...)` and is
     used by `ProcessingModel`.
3. **Diarization hang and cancel exposure.**
   - `EngineCall.run` wraps each diarization engine call (full file and each block). A token cancel cancels the
     Swift task, which FluidAudio honours in its loops, and the detached block task now forwards cancellation.
   - Liveness ticks reach the worker every 5 s, within a budget of max(120 s, 10% of audio length).
   - Tests: `ticksStopAtTheBudgetSoAHungCallIsStillDetected`, `cancellationStopsACooperativeCallPromptly`, and the
     real-model `cancellingMidMeetingStopsWithinSeconds`. That last test stops 0.41–0.45 s after cancel, and the
     reused diarizer then gives 4 speakers and DER < 25% on IS1009a.
4. **Document corrections.**
   - `storage/0001`: the test name and path, the actual load used, and the synthetic-clock caveat.
   - `processing/0001`: the loop is strictly serial (no "light stages alongside").
   - `models/0001`: a correction note on the "no dropped chunks" sentence.
   - `diarization/0001`: the attribution metric definitions and the echo limits.
   - `asr/0001`: the thin sample, in-sample tuning, where the chosen policy loses, the 14–36 min range, and that only
     v7/v8 are reproducible.

## Also addressed
- The stale-edit check now fails closed. If the reconcile input cannot be read back, the result is not published
  (`JobFailure.permanent`).
- The long path is renamed `benchmarkOnlyTranscribeLong`. `productionCodeNeverUsesTheChunkDroppingLongPath` fails if
  production modules call it or the decoder-state API.
- The empty `Tests/Recovery/` directory was removed. Recovery tests live in `Tests/Capture/` (`ForceKillTests`,
  `RecoveryTests`).
- New tracked items: 14 (the guard is blind to VAD-missed speech), 15 (`SourceMap` unwired), 16 (real-device drift
  and real-load force-kill).

## Verification after the changes
- `scripts/check.sh`: ALL AUTOMATED CHECKS PASSED. That covers 122 tests in 26 suites (previously 113), the app and
  worker build, and the os-gate, worker-crash and worker-hang self-tests.
- Self-tests `pipeline-e2e`, `kill-worker-while-recording` and `hung-worker-recycled`: all pass
  (`evidence/2026-10-16/selftest-*.jsonl`).
- production-eval: WER, DER and attribution are unchanged from v7, since words are identical. Only coverage changed.
- Addendum (after v2 PASS): `TranscriptRevision.validate()` now rejects overlapping coverage per source; multi-window tiling test `coverageTilesAcrossWindowsAndSourceGaps` (123 tests pass).
