# Milestone C independent validation verdict

Validator: independent Sonnet agent. Hardware: one M2 Max / macOS 26.5.2. No source or docs modified; scratch only under /tmp.

## Overall: PASS WITH CONDITIONS

The automatable parts of T09/T10/T11 are largely real and the docs are mostly honest about the pending human gates. I reproduced the headline numbers. But I found (by code reading) one real functional defect (speaker edits after "Delete audio only"), one deletion-purge hole (job rows resurrected after complete deletion; unguarded check-then-insert races), a doc statistic that is wrong, and a recall proxy that is more lenient than the docs make clear. None block the human passes, but the first two should be fixed before Milestone D.

## What I ran
| Check | Result |
|---|---|
| `swift test --scratch-path /tmp/amaranth-validate-c` (full) | 149 tests / 32 suites: **148 pass, 1 fail**: `twoHoursFlatMemoryAndMarkersAlignedAfterNormalization` (growth 266 MiB vs <50). Re-run alone with `--filter`: **passes** (growth 1.8 MiB). So the failure is cross-suite contamination (process-wide footprint while real-model suites run in parallel). Flaky test design, not a capture regression. Notes/DataLifecycle/Presentation/Scheduler suites all passed. |
| `amaranth-bench notes-eval` (real Qwen3-4B, ~15 min, run while other jobs loaded the machine) | Planted 60 min 2/2, 120 min **6/6** (owners 6/6, deadlines 4/6), injection **10/10**: reproduced. Times 221 s / 483 s (docs 200/465; I had concurrent load). AMI numbers did NOT reproduce exactly: IS1009a recall proxy **5/7** (docs 7/7), 0 decisions + 2 actions (docs 0 + 4); ES2004a "1/1" with 0 decisions and 0 actions. |
| `ui-render` self-test | pass; 3,601-row meeting rendered in 0.58 s (doc 0.52 s). PNGs inspected: Notes tab (stale banner + Regenerate, "Owner: not stated", evidence time links, Limitations disclosure, Your notes, Private scratchpad with explicit toggle), transcript (overlap/uncertain flags, "Unknown speaker"), no-notes banner. Logged an AppKit warning: "reentrant operation in its NSTableView delegate... will become an assert in the future". |
| `pipeline-e2e`, `worker-crash`, `worker-hang` | all **pass**. e2e notes: 27 s, 11 items, 0 actions, 0 decisions, evidence valid (doc: 42 s, 16 items; run-to-run variance). |
| Not run (per rules) | capture-* self-tests, xcodegen/xcodebuild. |

## T09 Evidence-backed notes
Met, with evidence checked:
- Whole-meeting coverage: chunker covers every line (`makeChunks`, 17 chunks at 2 h); reduce caps pick evenly across timeline; planted items at ~5/7/60/62/115/117 min all found (reproduced).
- Valid evidence: ids filtered to the chunk, `validateReferences` at generation and again at commit; scratchpad lines only if `includeInSummary`; personal notes alone cannot make decision/action.
- Failure safety: failed chunk becomes a limitation; all-fail throws; `publishSummary` only swaps the current pointer on success, so prior summary stays; UI banner "Regenerating failed; these are the previous notes". User notes are separate records.
- One bounded repair: `extract` allows exactly 2 attempts (second with 8-item cap).
- Contradictions/revisions kept (`sameItem` refuses merge across negation/number mismatch).
- Scratchpad explicit (toggle, label, limitation, export disclosure). Staleness computed on read.
- No tool surface; nothing in the pipeline can act.

Unmet, overstated or unverifiable:
1. **Wrong statistic in notes/0001**: "31 of 81 items at 120 min uncertain". The run shows 4+18+20+15 = 57 reduced items, so it is **31 of 57 (54%)**, not 38%. Uncertainty is understated. (60 min: 21 of 46.)
2. **Recall proxy is lenient.** `NotesEval` counts a reference item as "recalled" if any generic keyword (e.g. "prepare", "marketing", "interface", "lost") appears anywhere in ANY item text of ANY kind (topics and questions included). Both AMI meetings yield 0 decisions. The "7/7" is not decision/action recall, and it varied (5/7 on my run). Docs say "keyword proxy" but do not say it is any-kind substring matching or that it is unstable run to run.
3. **Injection suite is a regression suite, not a held-out measure.** run2 log shows 9/10 before a fix (regex `looksAddressedToAI` + merge rule) targeted at the same 10 lines. Pass criterion is "keyword not in any item text". Defense is a regex list plus prompt. Not covered: injections through scratchpad, titles or speaker names; evidence-id spoofing; non-English; paraphrases outside the regex. The "by construction" claim (no tools, cannot change export/privacy) is true for the pipeline. Note, however, that note text and transcript flow unescaped (only `<` escaped) into Markdown exports, so injected `![](http://...)`/links survive in exported .md files (low).
4. **"Every item has valid evidence" = ids exist, not support.** Topics/questions get no model verification (only a 0.2 lexical test). Example in notes-review-planted-120min.md: overview/topic sentence names "Francina, Eileen, Jeanne-Oui, Betty (project manager)" but the cited lines (1:25:xx) contain none of those names ("Betty" comes from line 19:18, "Eileen" from 22:01). Many actions are weak (e.g. "Speaker 2 commits to documenting the notes", "Speaker 1 will implement search over the weekend"); most are flagged uncertain. Duplicates survive from the repeated synthetic text (double-click and "draw a cat" appear twice). The docs do acknowledge that human support/recall gates are pending; this is the evidence that they matter.
5. Synthetic 2 h transcripts are looped AMI meetings with crisp planted lines ("Final decision: we drop..."); easy compared to real calls. Doc says "real AMI reference speech" but not that the planted decisions are unnaturally explicit.
6. Minor: on resume, a cached failed extraction stays failed and `repairs` is under-counted (`repairAttempted` may be false); toggling or editing the scratchpad after generation does not mark notes stale.
7. Human quality gates (support/recall/owner/deadline), the real-call corpus: pending and clearly scoped (tracked items 6, 9, review sheets exist). 8 GB profile correctly not shipped. Notes speed (483 s per 2 h on M2 Max) is a flagged base-M2 risk (item 18).

## T10 Native recording and review UI
Met (evidence checked): thin SwiftUI over `Presentation` module; 10 Hz `Timer` polling of session snapshots (no per-callback publish); menu-bar item with state; closing window keeps recording; quit guard offers Stop, Save and Quit / Keep Recording; `stop()` is idempotent in `RecordingSession`; no discard path; permission, silent, interrupted, gap, saving-delayed and low-disk states exist in code; gaps are rows; playback-unavailable reason and "Owner: not stated" match between fixtures and store-backed tests (`PresentationIntegrationTests`, passing); `ui-render` screenshots agree. 2 h transcript: build 0.12 s, load 0.54 s, render 0.58 s (debug, M2 Max).

Unmet / overstated / unverifiable:
1. **Edit responsiveness is not measured**, only build/load/render. Every text correction runs `appendEdit` which re-indexes the whole meeting (decode 2 h transcript, ~3,600 FTS rows) and then a full detail reload. Likely fine on M2 Max, unmeasured.
2. Start/stop/save without terminal: code path only; nobody has driven it (checklist 2-7). Recorder/Quit/menu bar/TCC flows unverified.
3. Possible data loss in Notes pane: `debounceSave` (1 s) is cancelled by the next `onChange`; switching meetings within 1 s of typing when the other meeting's notes differ cancels the pending save for the first (not reproduced; add to checklist). Notes typed within 1 s of Quit are also lost (no flush).
4. Quit while `.preparing` (TCC prompt open): `stopThen` calls its completion synchronously, i.e. `NSApp.reply(toApplicationShouldTerminate:)` before `.terminateLater` is returned; behavior undefined (possible hang). Unverified, edge.
5. `finish()` may run twice if Stop and auto-stop race (enqueue is idempotent; harmless).
6. Fixture screenshot of the "edited" meeting shows notes owner "Dana" while the transcript still shows "Speaker 2" (rename lives only in reconcile). This is consistent with the design but shows renames never display without the reconcile job.
7. VoiceOver not audited (stated). Base-M2 unverified (stated). Tracked item 15 (empty SourceMap in production reconcile) still open, correctly listed.

## T11 Search, export, retention, deletion
Met (evidence checked, tests pass): exports built from the selected/display transcript and summary; scratchpad excluded by default (UI has no way to include it; the capability exists in the API only); stale/uncertain/personal-note disclosures; audio export lossless with manifest and gaps; audio-only deletion sets `.deletedByUser` first, removes segments/audio/work dirs, playback and `enqueuePipeline` fail; complete deletion tombstones first, `publishTranscript`/`publishSummary` are transactional and refuse tombstoned meetings; purge deletes all content tables, FTS rows (+`optimize`), WAL truncate with `secure_delete=ON`; raw-byte test for marker/title/notes/scratchpad passes; reopened store finds nothing; search ignores deleted meetings; dialogs say what stays and "cannot be undone" and mention earlier exports.

Defects / overstated:
1. **Speaker edits break after "Delete audio only" (code-confirmed, not run).** `deleteAudio` removes `work/<id>`, which holds the transcribe/diarize stage outputs that `reconcileInput` reads (`Data(contentsOf:)` throws). Renaming/merging/reassigning a speaker afterwards enqueues reconcile, which fails at input, so renames never appear. Docs/dialog promise that "transcript, notes and your edits stay". Also notes jobs still running lose their checkpoint directory. Fix: keep the stage outputs (or at least the transcript/diarization JSON, which are text), or make reconcile read from store revisions; add a test (speaker edit after audio deletion).
2. **Late results re-insert job rows after complete deletion.** `upsertJob` is unguarded: `commit()` (deleted branch), `heartbeat()` and the `.cancelled` path in `run()` call `store.upsertJob` after `purgeMeeting` removed `processing_jobs`; the scheduler test passes only because it accepts a `.cancelled` row (`allSatisfy { cancelled ... }`). Rows hold ids/hashes/checkpoint metadata, not transcript text, but contradict "purge removes every row". Related TOCTOU: `insertTranscriptRevision`, `insertDiarization`, `appendEdit` are not tombstone-guarded or transactional with the `deleted` check, so a result committing during a purge could re-insert transcript text. Narrow window; not reproduced.
3. The `work/` removal is not synchronized with a still-running worker (cancel is asynchronous), so a worker could write checkpoint files into the directory as it is removed (`try?` ignores failure). Narrow.
4. Doc says JSON contains the "contract revisions verbatim"; the transcript exported is the text-corrected display transcript (corrections applied). Defensible, but not verbatim.
5. Markdown export escapes only `<` (see T09 point 3).
6. Not verified: APFS snapshots/Time Machine (documented as out of scope); worker temp files; export UI hands-on; relaunch behaviour with the real app (only the store reopen test).

## Required fixes before Milestone D (prioritized)
1. Fix speaker edits after audio-only deletion (keep reconcile inputs or load from revisions) and add a test; also stop deleting a running notes job's checkpoints.
2. Guard job/revision writes against tombstoned meetings (transactional check in `upsertJob`, `insertTranscriptRevision`, `insertDiarization`, `appendEdit`), wait for the worker to acknowledge cancel before purging, and tighten the scheduler test to require zero job rows after deletion.
3. Correct notes/0001: 31 of 57 (not 81) uncertain; describe the recall proxy accurately (any-kind keyword substring; 0 decisions on both AMI meetings; varied 7/7 vs 5/7 across runs); say that the injection suite is a development set and the planted lines are explicit.
4. Fix the flaky `twoHoursFlatMemory...` test (measure per-session memory or run serialized) so a full `swift test` is green.
5. Notes pane: flush pending notes saves on meeting switch and quit; add the switch-within-1 s case and "quit while preparing" to `ui-manual-checklist.md`.
6. Add verification for topics/questions (or label them unverified in the UI) and the overview names-not-in-evidence case before the human review reads them.

## Acceptable deferrals
- Human notes evaluation, real-call corpus, interactive UI checklist, VoiceOver, capture/TCC flows (tracked items 1, 6, 9, 17).
- Base-M2/16 GB and 8 GB gates: **unverified**, no hardware.
- Notes speed levers and 1.7B model (item 18); item 15 source map; items 2, 4, 10-14, 16.
- Scratchpad-stale marking, markdown escaping hardening, extra injection variants (do before release).
- AppKit reentrancy warning (track; will become an assert).
