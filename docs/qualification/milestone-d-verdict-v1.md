# Milestone D (T14 live text) independent verdict

**Overall: PASS WITH CONDITIONS.** The delivered synthetic-replay behaviour is real and reproduces. The condition is bookkeeping: several statements are broader than the evidence, and two T14 deliverables are only partly met.

## Checked and met
- **Tests:** `swift test --scratch-path /tmp/amaranth-validate-d` passed in full. That includes `notesStateCoversEveryCase`, `liveTranscriberSettlesWordsIncrementally` (backlog=false: 2.1% WER; backlog=true: 1.1%) and `LiveTranscriptStateTests`.
- **Latency re-run:** I ran `--self-test live-latency` on the built Debug app (while `swift test` was also running, so under extra load). Result: median 2.13 s, p95 4.51 s, mic WER 3.6%, 0 missing-audio events, 0 ring overruns, app 92 MiB, worker 46 MiB, pass. This matches the committed evidence (2.18 s / 4.99 s, 2.4%, 91/45 MiB) and the claimed gates (<5 s, <10 s). I did not re-run `live-pressure`, `pipeline-e2e`, `worker-crash` or `worker-hang`, or the `amaranth-bench` build. The pressure figures (p95 11.3 s, caught up to 122-124 s of 124 s) rest on the 2026-10-16 JSONL only.
- **Durable audio only:** `App/Live/LiveTextModel.swift` reads `RecordingSession.snapshot()` committed segments. `ASR/Live/LiveTranscriber.swift` decodes the CAF files, filters on `state == .committed`, and never touches the realtime ring. It goes through the XPC `WorkerClient`, one request in flight. Under-yield guard and stable/tentative logic are present as described.
- **Provisional shown distinctly:** `LiveTranscriptView` uses a "provisional" label, MIC/SYS tags and dimmed italic tentative words, with no speakers. After Stop, `TranscriptPane` shows a banner and hides the correction and assign menus while `showingProvisional`. The provisional revision is stored as `.provisional`. Edits therefore only apply to final revisions, so the transition cannot lose them.
- **Pressure:** live text pauses on `thermalState` serious/critical, with a visible message. Capture is independent of it. The pressure self-test evidence shows `sawPaused`, `caughtUp` and 0 loss.
- **Item 21 fix:** correct and tested for the case it targets.
  - `notesState` returns `.waiting("Notes start when speakers are identified")` only when `transcript.stage == .asr` and a diarize or reconcile job is non-terminal.
  - If diarization failed (terminal) or no such job exists, it returns `.none`, so notes can still be generated from words alone. The test covers this.
  - The scheduler enqueues transcribe and diarize together, so there is no window where the transcript is ASR-only with no pending job.
  - The 26 s hold-up figure matches the evidence (notes 17-43 s, reconcile published at 43 s).
- **Restructure consistency (mostly):** the following agree that D = T14, E = T16-T21, F = T12+T13:
  - `implementation-tasks.json` (new `milestones` map, per-task milestone fields)
  - decision 0004 and the README row
  - the milestone-e plan
  - the live/0001 acceptance row
  - T12 depends on T14 and T21, and T13 depends on T12, so the "T12 and T13 must validate T14" chain is carried to F.
  - T13 is marked "partly implemented", so the 6ac994e claims about the release script, notices and tester guide have an owner.

## Unmet, overstated or unsupported
1. **"Persist finalized chunk results for reuse after Stop" is not delivered.** live/0001 honestly defers it, with a sound reason (energy gate instead of VAD, no right context). But the T14 task `status` still says "implemented (latency gate met...)" with no mention of the deferral. The deliverable text in the task file was not amended. Also, T19 explicitly does not reuse live output, so nothing owns the deferred reuse. Add an owner or an explicit "dropped" note.
2. **"Speakers shown distinctly" is vacuous.** There are no provisional speakers at all, and `Diarization/Live` is not built. The record says so ("no guessed speakers"), but the task deliverable and module_scope still imply otherwise.
3. **"Representative measured session set":** the evidence is one synthetic replay: mic from 10 LibriSpeech utterances and 120 s of AMI EN2002a, run twice or three times. The live/0001 qualifier ("synthetic replays ... real set unverified") is honest. The `Met` label in the T14 status should not be read as met on a representative set. The one real recording persisted no latency samples (`latencySamplesPersisted: false`), so there is no real-world latency evidence. The "about N s behind" UI figure is the only live measurement, and it is not stored.
4. **Pressure gate wording:** the `live-pressure` self-test returns pass without checking p95. p95 was 11.3 s (>10 s). This is documented as by design, but the table shows it next to a gate it fails. Suggest labelling the p95 gate "not applicable during a pause".
5. **Memory pressure claim:** the `LiveTextModel` doc comment says it pauses under "thermal/memory pressure", but `pauseReason` checks only thermal state. No memory trigger exists.
6. **Concurrent call plus live inference:** "Met" is synthetic only (zero loss, 91 MiB). The thermal gate is not exercised in any real run; the thermal pause is simulated. The real recording ran live text, but its `capturedWithGaps` start delays (permission prompt, manual playback) mean it is not usable evidence for first-frame timing, and there were 5 provisional revisions (which matches ~127 s at a 30 s publish interval).
7. **Capture-checklist row marked "Pass":** this is a Debug-build, local-player run that ended `capturedWithGaps`. "Pass" is acceptable only if the row's note keeps those caveats, and the note does. I would still prefer "Pass (Debug, local player only)", since the other rows are for real meeting apps and release builds.
8. **Tracked item 2 is accurate but unhelpfully coarse.** It is still "Open", which is safe. The shipped code and tests do partly address it:
   - overlap alignment: 2 s left context with midpoint word assignment, tested incrementally
   - first-word handling: covered by the incremental test, with no duplicates and no re-emission
   - measurement under concurrent capture: synthetic (two real-time sources plus the real worker), zero loss

   Not resolved: padded final-window flush at Stop (live uses a 3 s wait, then publishes whatever tentative text exists, and no test covers the last words), and any real concurrent-call measurement. Split the item into done (synthetic) and open (flush, real call), and re-owner the remainder to F.
9. **T12/T13 do not mention live text.** The T14 acceptance line is carried only through the `depends_on` chain and the `promotion_note`. T12's deliverables and acceptance never mention live text, so Milestone F could pass without testing it. Add a live-text line to T12.
10. **Item 21 test gap:** only the reconcile-pending case is tested. A diarize-pending-only case and a suspended-diarize case (recording active) are untested; the wait message for a suspended diarize says nothing about why. Cosmetic.
11. **Commit 6ac994e claim "end-to-end processing-timing self-test (T12)":** T12 is `planned` with no mention of this self-test or its 60-minute timing evidence (`selftest-processing-timing-60min.jsonl`). It is not unowned but it is unreferenced, so F should list it as partial T12 work, as was done for T13.

## Could not verify
- Any base-M2/16 GB or 8 GB behaviour (unverified, correctly stated).
- Real-call live latency, since no real latency samples exist.
- `live-pressure` and the worker/pipeline self-tests (not re-run).
- Release-build behaviour (Debug app only).
- The interactive appearance of the live pane (I read the code only).

## Required before Milestone E
1. Amend the T14 task record: status and deliverables should state that reuse after Stop is deferred and that no provisional speakers exist, and name an owner (or say dropped).
2. Add a live-text validation line to T12 (or T21/F acceptance) so "T12 and T13 validate T14" is testable, and list the first-real-meeting and processing-timing evidence as partial T12 inputs.
3. Split tracked item 2 into synthetic-done and open parts, naming the padded final-window flush at Stop as an open item; fix the memory-pressure comment (or add the trigger).
4. Label the p95 pressure gate and the "Pass" checklist row with their caveats.

## Acceptable deferrals
- Real-call latency, thermal and concurrent-capture evidence (to F, via checklist).
- Base-M2 and 8 GB gates.
- Chunk reuse after Stop, provided it has an owner or an explicit drop.
- Diarize-pending-only test case for item 21.
- Persisting live latency samples (a T20 prerequisite for "real recordings", which T20's gate requires).
