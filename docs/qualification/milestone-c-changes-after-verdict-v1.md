# Milestone C: changes made in response to validator verdict v1 (PASS WITH CONDITIONS)

## Required fixes
1. **Speaker edits after "Delete audio only".**
   - `deleteAudio` now removes only audio: the meeting audio folder, `prepare-*` analysis audio, and any audio file
     under `work/<id>`.
   - Text stage outputs (transcript and diarization JSON, notes checkpoints) stay.
   - Tests: `speakerEditsStillWorkAfterAudioOnlyDeletion`, and the audio-deletion test now asserts that no audio file
     remains.
2. **Tombstone guards.**
   - `upsertJob`, `insertTranscriptRevision`, `insertDiarization`, `appendEdit`, `saveScratchpad`, `saveManualNotes`
     and the capture record inserts are no-ops for a tombstoned meeting, checked inside each write's own transaction
     (`MeetingStore.isTombstoned`).
   - When a job of a deleted meeting finishes, the scheduler removes `work/<id>` again.
   - `deletionDuringProcessingNeverPublishesLateResults` now requires zero job rows and no work folder after the
     late worker finishes.
3. **Documentation.**
   - notes/0001: uncertain is 31–33 of 57; the recall proxy is described as any-kind keyword matching with run-to-run
     variation and 0–1 decisions; the injection suite is a development set; the planted lines are explicit; topic and
     question verification rules are stated.
   - data/0001: JSON carries the displayed (corrected) transcript; audio deletion keeps text outputs; tombstone guards
     described.
   - ui/0001: edit round trip measured; save flushing; the AppKit warning noted.
4. **Flaky memory test.** The two-hour session runs in the child recorder process (`amaranth-recorder-child --long`)
   and asserts that process's footprint: 1.6 MiB growth in the full parallel `swift test` run. The full suite is green
   (150 tests).
5. **Notes pane.**
   - Pending saves have one slot per field and are flushed synchronously on meeting switch, view disappearance and
     app termination.
   - Quit while recording is still starting replies asynchronously.
   - Checklist items 17–18 were added.
6. **Grounding.**
   - Unsupported capitalised names, like unsupported numbers, now doubt an item: it is verified and stays uncertain
     even if the verifier says "yes".
   - Overview sentences whose names or numbers aren't in their cited items' lines are dropped (one was dropped on
     IS1009a in the latest run).

## Also addressed
- Scratchpad changes after generation (newly included, edited while included, or switched off) make notes stale.
- Markdown export escapes Markdown and HTML in spoken and generated text (test: injected image, link and HTML stay inert).
- The evidence-jump selection is deferred to the next run-loop turn (AppKit reentrancy; tracked item 19).

## Verification after the changes
- `scripts/check.sh`: ALL AUTOMATED CHECKS PASSED (150 tests in 32 suites; app build; os-gate, worker-crash and
  worker-hang self-tests).
- Self-tests `pipeline-e2e` (now including notes through the real worker), `kill-worker-while-recording`,
  `hung-worker-recycled` and `ui-render`: all pass (`evidence/2026-10-16/selftest-*.jsonl`).
- notes-eval (latest `run.log`): planted 60 min 2/2 and 120 min 6/6 (owners 6/6, due 4/6); injection 10/10; AMI
  IS1009a proxy 6/7, ES2004a 0/1; 204 s and 475 s.
