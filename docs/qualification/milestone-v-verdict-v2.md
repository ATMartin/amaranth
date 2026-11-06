# Milestone V validator verdict v2 (independent, 2026-11-06)

**Verdict: PASS WITH FIXES** (no must-fix blockers; one small should-fix regression)

## Verified fixes (working tree)
- Must-fix 1, attributionViolation (Presentation/ContextualAsk.swift:62): the regex now matches "I'll send it by Friday.", "You’ll send the deck" and "We'd review". It does NOT match "Speaker 2 said they'd send it; I can't tell which speaker is you." I ran the pattern in Python. The two new test lines are in ContextualAskTests.
- AnswerModel.timeOut now cancels the "", -plan, -q and -x requests (App/Library/AnswerModel.swift:202).
- sourcesChanged now compares contextGenerations against the generations recorded at delivery. It also handles deletion (missing meeting). Because answeredGenerations is set only on the .answer path (line 178), a meeting that has no recorded generation is not flagged for edits. That is acceptable because every shown answer passes through line 178.
- The retriever fallback (Contextual/ContextualRetriever.swift:283) skips day and month names and "i".
- rechunkAll (Storage/Search/ContextIndex.swift:97) now skips an undecodable row instead of throwing.
- Whole-word grounding is in place (Domain/Search/ContextualSearch.swift:149). A test for "Al" against "also" was added.
- Tests: the filtered run passed (ContextualAsk, Chunker, ContextIndex, ContextualRetriever, ConstraintResolver, Answerer), 0 failures.

## Remaining should-fix (not blocking)
1. Whole-word grounding regression, Domain/Search/ContextualSearch.swift:149.
   - The tokenizer keeps `'` and `.` inside words, so a question token like "al's" (possessive) or "al." (sentence end) no longer matches the name "Al".
   - "What did Al's team say?" and "Ask Al." therefore drop a valid planner person constraint.
   - This only widens recall within scope, and it falls back to the keyword and fallback paths, so there is no leak.
   - Fix: strip a trailing `'s` and trailing periods from tokens before comparing.
2. The fallback planner is still a duplicate of QueryPlanner.fallback, with a separate hard-coded list. This is cosmetic.
3. Items 3 and 6 from v1 (visible unchecked stream text, resident encoder on 8 and 16 GB machines) remain as documented limits.
4. The T116 harness and result files are still uncommitted. Commit them before install. Back up the library before installing, because v6 apps cannot open v7.

Not re-verified: benchmarks, ui-render-ask and the App-target UI. Only the diff and the unit tests were checked.
