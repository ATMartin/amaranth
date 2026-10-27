# Milestone N verdict: PASS WITH FIXES

## Must-fix
1. Keyboard-only Return does not open the hit highlighted with up/down (checklist 46 fails). Seen 3 times on the real app (Dark and Light): up/down highlight works, Return clears the highlight and leaves the panel open, nothing opens. Likely cause: `LibraryModel.query` didSet (App/Library/LibraryModel.swift, `var query ... didSet { ...; askSelection = nil }`) fires when the TextField commit rewrites the binding with the same text, before `onSubmit` -> `submitAsk()` reads `askSelection`. Fix: clear selection only when `oldValue != query`. ui-render did not catch it because it drives the model directly (Tests/UI/AskAnythingTests.swift and UIRenderSelfTest "ask" step); add a test that sets query to the same value then calls submitAsk.

## Should-fix
- Keyword "Matches" use AND of all content words (Storage/Search/SearchIndex.swift search: tokens joined by space). A natural 5-word question showed "No matches." under the answer; add OR fallback / fewer-words fallback.
- Eval "Correct" means only "cited an expected line" (AskEval.swift). It is not answer correctness. Reports/decision 0003 headline "40/42 correct" over-claims. Seen in the committed report (reproduced exactly offline): q26 invents a meeting title and says it is the only meeting; q41 lists passage labels as meetings; q22 cites 1 of 2 expected meetings yet counts correct. Relabel the metric or add a content grade.
- Question set is not held out: the same agent wrote q21-q42, saw cross-meeting results (4/11 -> 8/11 for 2+ meetings, 14/22 -> 40/42), then changed answer-v2 prompt, the "addressed to AI" checker pattern and refusal detection. Notes 0003 calls it "independent"; say it was used for tuning.
- Eviction/yield: busy check is only pre-flight (App/Library/AnswerModel.swift busyReason loop). Nothing cancels an in-flight answer when Record starts, and ModelProvider.answers() -> notes() releases ASR/diarizer/live ASR (InferenceWorker/Runtime/StageRunner.swift ~131). After any ask the speech models stay unloaded, so the next Record/transcription pays an ASR reload (not measured). Cancel on recorder start; measure/mitigate reload.
- Docs stale: data/0002 says overlapping windows are merged and cites 8.4 ms max; code has maxSpan 6 + claimed-lines, and my corpus run shows longest max 11.9 ms. No unit test for the 6-row cap / no shared lines. Memory of the second 6,144-token llama context is not measured or documented.
- Minor: ui-render leaves hundreds of amaranth-ui-render-*.plist in ~/Library/Preferences (pre-existing).

## Needs a person
- Checklist 49: Record and ask during recording (must wait/pause), Wi-Fi off while asking, and VoiceOver pass over the field, panel, chips.
- Re-check Return-to-open with a physical keyboard after the fix (my keystrokes were synthetic via System Events).
- Real work-Mac library (6+ meetings, Leesa/Andrew/Moxee) was not available here: this machine's library has 3 meetings. Check v2->v4 migration there (test copy took 260 ms) and subjective answer quality.
- Install Release build over the installed app (installed app refuses schema v4).

## Checked
- swift test (AskAnything|AskFollowUp|Retriever|Answer|MeetingStoreTests|DataLifecycle): all pass; corpus latency longest meeting median 0.8 ms, max 11.9 ms (< 50 ms).
- ui-render passes (light and dark); ask-worker self-test passes (real XPC, streamed, refusal).
- Offline eval (sandbox-exec, no network) reproduced committed T55 report: 42/42 citations valid, 40/42, cross 10/11 and 8/11, follow-ups 6/6, injection 15/15, first text max 2.73 s, full max 5.0 s.
- Real DB: migrated v3 -> v4 cleanly on first launch (546 transcript rows all with evidence, 388 with speaker, 38 notes with evidence, integrity_check ok, counts stable); no person/speaker rows since none exist.
- Hands-on (Dark and Light): bar pinned bottom and never covers transcript (safe-area inset; panel is an overlay only while open); sidebar search gone; Cmd-K focuses with All meetings; scope switch; grouped hits with highlights; mouse click on a cross-meeting hit and on a citation chip jump to correct meeting/row; follow-up resolved a pronoun and showed the earlier turn dimmed; injection question refused with no prompt leak; "may be wrong" caption shown; refusals and "No matches" fine. Recording tab untouched. Never recorded/edited/exported.
- Staffing call: only appears in AskEval.swift as the purge filter; not in questions.json. Staffing with transcription (consented) is used.
- Code: Retriever (bm25 weights, prefix/stem, quoted terms so no FTS injection, +-2 windows capped at 6 rows, no shared lines, top 12, evidence), reindex on rename/setPeople, migration (1..<4) idempotent, answer worker cancel path, citations validated against sent passages.
