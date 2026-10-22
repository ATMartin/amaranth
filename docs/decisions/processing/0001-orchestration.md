# Processing 0001: Isolated, resumable orchestration (T08)

Date: 2026-10-16 · Task: T08 · Status: Accepted for v0.

## Decision

**Where things run.**
- The app owns the **scheduler** (`InferenceWorker/Core/JobScheduler.swift`, module `ProcessingCore`).
- All inference runs in the bundled **XPC worker** `com.alexmartin.amaranth.InferenceWorker`
  (`InferenceWorker/Service/main.swift`) through `StageRunner` (module `ProcessingRuntime`). Inference never runs in
  the capture process.
- XPC messages carry only job descriptors and output paths/hashes. Stage inputs and outputs are files in the job's
  work directory (`input.json` → `output.json`, written atomically, SHA-256 recorded on the job).

**DAG.** `prepare → {transcribe, diarize} → reconcile` per meeting. Notes come with T09.
- Jobs are keyed by content: meeting, stage, input hash and config hash. Enqueue is idempotent.
- The config hash includes `asr-pipeline-v7` and `diar-v1`, so a pipeline change re-runs only the affected stages.

**Concurrency.** *(Amended by processing/0002, T17: transcription and diarization now overlap.)* The loop runs **one stage at a time**, strictly serially, so in particular one heavy stage at a time.
Light stages (prepare, reconcile) are not run in parallel either. Models are cached in the worker between jobs and
released when the worker exits.

**Leases and heartbeats.**
- Running jobs hold a lease with an owner and heartbeat.
- On launch, jobs left `running` by a dead process are requeued, not duplicated.
- `WorkerExecutor` runs a heartbeat watchdog. A worker that sends no progress for 300 s is treated as hung, killed and
  recycled.
- Stages report progress per ASR window. During each long diarization engine call, they send liveness ticks for up
  to a budget of 10% of real time, at least 120 s (diarization/0001). A call that runs past its budget and then 300 s
  more is treated as hung.

**Retries.**

| Failure | Retry policy |
|---|---|
| `workerLost` (crash, hang, kill) | Retried with backoff |
| `stageFailed` | Retried once, then failed |
| `permanent` (missing inputs or models) | Not retried; the user can retry |

**Pressure.** Heavy stages are **suspended**, never shown as stuck, while any of these hold:
- a recording is active;
- the thermal state is serious or critical;
- there is a memory-pressure warning or critical event.

The meeting status shows "waiting: recording active", "waiting: thermal" and so on.
- A heavy stage that is **already running** when pressure appears gets a cancel request within about 250 ms. The
  stage stops at its next checkpoint (the current ASR window, or FluidAudio's internal checkpoint, measured at about
  0.4 s) and becomes `suspended`, not failed. It resumes when the pressure clears; ASR keeps its window
  checkpoints.
- The app's signal policy is `JobScheduler.Pressure.current(recording:thermal:memoryPressure:)`:
  1. recording;
  2. otherwise, thermal state serious or critical;
  3. otherwise, a memory-pressure warning or critical event.

**Stale results.** Publishing goes through the store's single writer.
- A result for a tombstoned (deleted) meeting is refused.
- A reconcile computed from edits that have since changed is discarded and recomputed.
- The check fails closed: if the input a result was computed from cannot be read back, the result is not published
  and the job fails permanently.
- Edits made during reconcile are never overwritten.

## Evidence

Scheduler tests: `Tests/Jobs/SchedulerTests.swift`, 11 pass. They include `runningHeavyStageYieldsWhenRecordingStartsAndResumesAfter`,
`thermalAndMemoryPressureSuspendHeavyStages` (thermal and memory cases) and `pressurePolicyMapsAppSignals`. App self-tests through the real XPC worker and the
installed model pack (no audio permission needed; synthetic replay of public audio) are in
`evidence/2026-10-16/selftest-*.jsonl`.

| Acceptance (T08) | Evidence | Result |
|---|---|---|
| Kill/hang the ML worker while recording: committed audio continues and the failed stage retries | `kill-worker-while-recording` self-test: the real worker is SIGKILLed at 15% of transcribing meeting A while meeting B records at 20× replay. Meeting B has 31 segments after the kill, is contiguous, and has 0 missing-audio events; transcribe succeeds on attempt 2. In this test, pressure is deliberately set to `.none` so the worker is busy during recording; production suspends heavy stages instead. `hung-worker-recycled` (hang fault → watchdog → new worker PID → pipeline completes); `worker-crash` / `worker-hang` in `scripts/check.sh` | Pass. Recording kept committing, and the stage retried on a fresh worker. At 60× replay, the harness itself overruns (a replay limit, not an app limit). |
| Second meeting right after the first, with a cold model and a failed prior stage | `secondMeetingRightAfterTheFirstWithColdModelAndFailedPriorStage`: meeting 2 records while meeting 1 is queued; meeting 1's diarize fails permanently; meeting 2 still completes; meeting 1 keeps its ASR result, shows the failure, and completes on retry. The real cold-model case is covered by `pipeline-e2e` on a freshly launched worker. | Pass. The "failed prior summary" is simulated with a failed diarize stage, since notes (T09) are not built yet. |
| Relaunch requeues incomplete jobs without duplicate output or lost edits | `relaunchRequeuesJobsLeftRunningByADeadProcess`, `editsDuringReconcileAreNotOverwritten` | Pass |
| Cancellation, deletion and stale revisions have deterministic tests; worker cleanup is bounded | `deletionDuringProcessingNeverPublishesLateResults`, `resultComputedFromStaleEditsIsDiscardedAndRecomputed`; ASR cancel/resume test; `hung-worker-recycled` | Pass |
| End to end through the real worker | `pipeline-e2e`: prepare → transcribe → diarize → reconcile; 4 speakers, mic WER 1.2% | Pass |

## Limits

- Models stay cached in the worker. Unloading ASR and diarization before the LLM loads (plan §10) is T09's
  responsibility once notes exist.
- ~~Core ML warm-up is not yet wired into the installer~~ Done in T17 (processing/0002): the app asks the worker to
  load the models after a pack installs (tracked item 3).
- Processing-time gates on base-M2/16 GB are **unverified** (no hardware).
