# Milestone N verdict v2: PASS

## Must-fix
None. The v1 must-fix is fixed in the real app.

## Should-fix (minor, none blocks)
- Stale comment in InferenceWorker/Runtime/StageRunner.swift (answerConfiguration) still says "2,600-token prompt budget"; the budget is now 2,200.
- changes doc lists RetrieverSpreadTests as new; it already existed at HEAD (only RetrieverWindowTests is new).
- The Return-keeps-highlight fix is covered only by ui-render (library.query = library.query), not by a unit test in swift test.
- The 0.2 s "speech models reload" measures 2 decoders + 2 VADs with a warm Core ML cache; the diarizer and live ASR are not included, and a cold cache is not measured.
- Hand grading marks q15 "partly" and q04 "right"; both are defensible. No grade I checked was inflated.

## Needs a person
- Checklist 49: Record and ask while recording and while transcribing, Wi-Fi off, VoiceOver over field, panel, chips.
- Return-to-open with a physical keyboard (my keystrokes are synthetic via System Events, though they went through the real key path).
- Work-Mac library v2 -> v4 migration and subjective answer quality.
- Install the Release build before opening the library with it.

## Checked
- Must-fix, real Debug app, keyboard only (System Events key codes, no clicks), real library:
  - Light: Cmd-K, "think", Return, down, down, Return. The 2nd hit highlighted, then opened Build Carolina check-in at row 39:53, and the panel closed. Return then reopened the same results (the earlier answer still shown). Up from no selection highlighted the last hit (wraps). Esc closed the panel. Return again brought the results back.
  - Dark: same sequence with "people". The highlighted hit (23:07) opened in the right meeting and row and the panel closed. Return after that, up, Esc and Return again all worked.
  - Code: LibraryModel.query didSet now has `guard query != oldValue`. ui-render sets the same text before checking the highlight and passes.
- ui-render self-test passes (png2/); ask, ask-cross-citation and ask-answer steps ok. The Preferences folder now has just 2 fixed amaranth-ui-render-*.plist files, not hundreds.
- swift test "AskAnything|AskFollowUp|Retriever|Answer": all pass, 0 failures. The new RetrieverWindowTests (6-row cap, no shared lines) and the AskAnything anyTerm test ("budget unicorn" gives none, any-term gives 2) are present.
- Any-word fallback: MeetingStore.search(anyTerm:) joins quoted prefix terms with OR (still no FTS injection); LibraryModel.runSearch falls back only when the all-words search is empty.
- Eval relabel: report.md and AskEval.swift now say "Cited an expected line ... not a judgement of the answer text". Hand grading in notes/0003 sums to 42 (31/6/3/2). Spot-checks against answers.json and questions.json: q18 (says $100, expected $200: wrong), q26 (invents a meeting title: wrong), q41 (lists passage labels: wrong), q10 and q30 (refused though answerable: confirmed) all match.
- "Not held out" statement is in notes/0003, plus that answer-v2, the checker and the budget were tuned on the set.
- Record cancels the answer: AmaranthApp onStarted calls library.answers?.cancel() before recordingStarted. I did not press Record.
- Resources and latency, in run.log and report.md:
  - Context 3,072 (StageRunner.answerConfiguration and AskEval).
  - Memory line "answer context adds 436 MB" (notes model + context 3,594 MB).
  - Reload 0.22 s and 0.21 s.
  - First text max 2.23 s, median 1.81 s, under the 3 s target. Full max 4.60 s. Budget 2,200 in Answerer.promptBudget.
  - Cross-meeting 2+ meetings 7/11 is reported honestly.
  - AskEval's raw-output check now uses Answerer.fittedPrompt.
- data/0002 matches the code (maxSpan 6, claimed lines) with re-measured timings (longest max 12.0 ms, my earlier 11.9 ms).
- No new regressions seen. Sidebar, meeting selection and the Recording tab behaved normally. Nothing recorded, edited, exported or deleted. I did not re-run the full eval.
