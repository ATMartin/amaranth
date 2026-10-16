# Milestone C re-validation verdict v2

Validator: independent Sonnet agent, M2 Max / macOS 26.5.2. No source/docs modified; no capture self-tests; scratch under /tmp.

## Overall: PASS WITH CONDITIONS (conditions are minor; no blocker for Milestone D)

All six v1 required fixes are present in code and verified by running tests. Full `swift test --scratch-path /tmp/amaranth-validate-c`: **150 tests / 32 suites, all pass** (131 s). The flaky memory test is fixed: the 2 h session runs in the recorder child process and reports "recorder-process footprint growth 1.3 MiB (minute 15 -> end), max 10.9 MiB" inside the full parallel run. Self-test `ui-render`: pass (3,601 rows, 0.48 s). notes-eval re-run: planted 60 min 2/2, 120 min 6/6 (owners 6/6, due 4/6), injection 10/10, 208 s / 491 s. I did not re-run pipeline-e2e/worker self-tests (unchanged v1 results; the changes doc cites passing evidence files).

## v1 findings: status
| # | v1 finding | Status | Evidence checked |
|---|---|---|---|
| 1 | Speaker edits break after "Delete audio only" | **Fixed** | `deleteAudio` now removes the meeting audio folder, `prepare-*` stage folders and any wav/caf/aiff/m4a/pcm under `work/<id>`; transcript/diarization JSON and notes checkpoints stay (ASR window checkpoints are JSON text, so no audio leaks). Test `speakerEditsStillWorkAfterAudioOnlyDeletion` passes; audio-deletion test asserts no audio file remains. |
| 2 | Job rows resurrected / unguarded check-then-insert | **Fixed** | `isTombstoned` checked inside each write's own transaction in `upsertJob`, `insertTranscriptRevision`, `insertDiarization`, `appendEdit`, `saveScratchpad`, `saveManualNotes`. Scheduler removes `work/<id>` in the run `defer` (after `execute` returns, so the worker has finished) when the meeting is deleted. `deletionDuringProcessingNeverPublishesLateResults` now requires zero job rows and no work dir; passes. |
| 3a | notes/0001 "31 of 81" | **Fixed** (now 31-33 of 57; my run: 33 of 57 at 120 min, 23 of 46 at 60 min) |
| 3b | recall proxy description | **Fixed in docs**; but variance is wider than documented: my run IS1009a 3/7, ES2004a 0/1 (docs 6/7, 0/1; v1 run 5/7, 1/1). Doc should state the 3/7-7/7 range. |
| 4 | Flaky memory test | **Fixed** (see above) |
| 5 | Save flush / quit-during-preparing / checklist | **Fixed with one new defect** (see R1) |
| 6 | Topic/overview grounding | **Implemented**; see R2 on over-dropping |
| - | Scratchpad changes mark notes stale; Markdown escaping | Implemented per change list; tests pass (not re-audited line by line) |
| - | AppKit reentrancy warning | **Not eliminated**: `ui-render` still logs "reentrant operation in its NSTableView delegate". The doc notes it and tracks item 19, so acceptable, but it is not fixed. |

## New or remaining issues
- **R1 (new, low-medium): scratchpad toggle can be silently reverted.** In `NotesPane`, the text save captures `include` at typing time. If the user types and flips "Use these private notes" within 1 s, the toggle saves (text, true) immediately, then the pending 1 s save fires `saveScratchpad(text, include: false)` and writes a newer revision with the switch off. Because inclusion is a privacy choice, the user's last explicit choice is lost (safe direction: private notes become excluded, but the UI toggle then disagrees until reload). Fix: have the pending closure read the current toggle value, or cancel the pending text save when the toggle fires. Not covered by a test; add to the manual checklist.
- **R2 (new, low): grounding checks may over-drop.** notes-eval logs `droppedOverviewSentences=3` on ES2004a (a one-chunk meeting that yielded 7 topics and 2 questions) and 1 on IS1009a; the ES2004a overview may now be empty. The capitalised-name check also treats any mid-sentence capitalised word absent from the cited passage (titles like "Marketing Manager", month/day names the model normalises) as unsupported, which forces extra verification and keeps items uncertain. This is conservative and honest, but it is a quality cost the human review sheets should measure (does an empty overview still read acceptably?). Planted 6/6 and 10/10 injection are unaffected; uncertain count went up slightly (33 of 57, 23 of 46).
- **R3 (v1 carry-over, low):** start/stop/save without a terminal, edit responsiveness on a real machine, VoiceOver, base-M2/8 GB remain **unverified** (human checklist items and tracked items 1, 8, 9, 17 stand). Note speed is still ~490 s per 2 h on M2 Max (item 18).
- **R4 (low):** injection suite is a development set (documented); no new variants added.
- **Tombstone-guard regression review:** no problem found. `isTombstoned` returns false for unknown meeting ids, so fixtures and recovery of unknown ids still write; `JobScheduler.cancel` after tombstone now no-ops on job rows (they are purged next anyway); `retry` cannot revive jobs of deleted meetings. Recovery replay for a tombstoned meeting is blocked as intended. I found no path where the guard blocks a legitimate write for a live meeting. Audio-only deletion leaves no known audio files; a running notes job keeps its checkpoints.

## Required before Milestone D
1. Fix R1 (pending scratchpad save must not override a newer toggle) and add a unit-level or checklist check.
2. Update notes/0001 with the observed recall-proxy range (0/1-1/1 and 3/7-7/7 across runs) and mention overview sentences can be dropped entirely on short meetings.

## Acceptable deferrals
- Human notes evaluation, real-call corpus, interactive UI checklist (incl. new items 17-18), VoiceOver, capture/TCC flows.
- Base-M2/16 GB and 8 GB gates: **unverified**.
- Notes speed levers (item 18); AppKit reentrancy warning (item 19); broader injection suite; items 2, 4, 10-16.
