# Milestone D: changes after verdict v1

| Verdict v1 item | Change |
|---|---|
| Required 1: T14 record overstates delivery | `implementation-tasks.json` T14: status says "implemented, with deferrals"; new `deferrals` list: chunk reuse after Stop not delivered and superseded by T19; no provisional speakers (Diarization/Live not built); one synthetic replay only, real-call latency to T12 |
| Required 2: T12/T13 don't mention live text | T12 gets a live-text deliverable and acceptance line, and its status lists its partial inputs (processing-timing self-test, first-real-meeting evidence). T13 acceptance includes live text in the packaged build. |
| Required 3: item 2 too coarse; memory-pressure comment | Tracked item 2 now covers only the parts done on synthetic input. The open final-window flush is item 23 (owner T20), and the real-call measurement goes to T12. The `LiveTextModel` comment now says thermal only; the memory trigger is a T19 deliverable. |
| Required 4: caveats on the pressure p95 and the checklist row | live/0001 pressure p95 is "gate not applicable during a pause; the self-test does not check p95". The checklist row is "Pass (Debug build, local player only)". |
| Deferral: item 21 diarize-pending test | Added: diarize queued, diarize suspended (recording active), and diarize failed (generate allowed) cases in `notesStateCoversEveryCase` |
| Deferral: persisted latency samples | T20 deliverable |
| Also | `.gitignore` now excludes `Tests/Data/Recordings/` (the user's consented corpus; never committed) |
