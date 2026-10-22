# Milestone D re-verification (v2)

**Overall: PASS.** All four required items from v1 are fixed in the files. No required fixes remain before Milestone E.

## Required items
1. **T14 record (fixed).** `implementation-tasks.json` T14 status now reads "implemented, with deferrals". A new `deferrals` list covers three things:
   - chunk reuse after Stop is not delivered, and is superseded by T19;
   - no provisional speakers are shown, and Diarization/Live is not built;
   - the evidence is one synthetic replay, with real-call latency going to T12 and persisted samples to T20.
2. **T12/T13 live text (fixed).** T12 has a live-text deliverable and an acceptance line (real-call latency, capture/memory/thermal gates, live-to-final transition). Its status lists the partial inputs: the processing-timing self-test and evidence, and the first-real-meeting evidence. T13 acceptance now includes live text in the packaged build.
3. **Tracked item 2 and the memory comment (fixed).**
   - Item 2 now covers only the synthetic-input parts, with the test and self-test evidence named.
   - The final-window flush is new item 23 (open, owner T20), and the T20 deliverable exists.
   - The real-call measurement goes to T12.
   - The `LiveTextModel` comment now says thermal only. The memory trigger is a T19 deliverable.
4. **Caveats (fixed).** live/0001 marks the pressure p95 as "gate not applicable during a pause", noting that the self-test does not check p95. The checklist row now reads "Pass (Debug build, local player only)".

## Deferral item
- **Item 21 diarize-pending tests (added).** `notesStateCoversEveryCase` now covers diarize queued, diarize suspended while recording, and diarize failed (notes allowed). I re-ran `swift test --filter PresentationLogicTests`: all 4 tests passed. I did not re-run the rest of the suite or the self-tests.
- T20 now includes persisting latency samples.

## Other checks
- `.gitignore` excludes `Tests/Data/Recordings/`. I did not open anything in that directory.

## Remaining and unchanged
- Base-M2/8 GB, real-call live latency and the thermal gate remain unverified, as already recorded. They are owned by F/T12.
- The Debug app is the only build exercised.
