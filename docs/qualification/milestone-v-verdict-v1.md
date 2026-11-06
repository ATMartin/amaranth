# Milestone V validator verdict v1 (independent, 2026-11-06)

**Verdict: PASS WITH FIXES**

The qualification is honest. Every number I re-derived matches the files, and the misses are reported as misses. I found no scope, deletion or date leak, no network code, and no inference dependency in Storage or MeetingAccess. The v6 to v7 migration and the installed-app transcription path are safe. One small identity hole needs fixing before install (must-fix 1). The rest are should-fix items.

## Must-fix

1. **The "you/I" attribution post-check misses contractions.** `Presentation/ContextualAsk.swift:~68` (`attributionViolation`).
   - The regex needs whitespace between the pronoun and the verb: `(i|you|we)\s+(... |'ll|’ll ...)`.
   - "I'll send it", "You'll send the deck" and "you'd" never match. I confirmed this with the same pattern: "You'll send the deck." gives False, while "You promised" gives True.
   - "I'll" and "you'll" are the most natural promise phrasings. With the user unmapped, the wrong-person safeguard (A4) is bypassed for exactly those answers.
   - Fix: allow an optional apostrophe form, e.g. `(i|you|we)(\s+|(?=['’]))(…)` or `(i|you|we)['’](ll|d|ve)`. Add a test in `Tests/UI/ContextualAskTests.swift`.

## Should-fix

1. **`AnswerModel.timeOut` cancels only the answer request.** `App/Library/AnswerModel.swift:~207`.
   - `cancel()` also cancels the `-plan`, `-q` and `-x` requests, but `timeOut` and the watchdog do not.
   - After the 15 s watchdog, a still-running planner generation or embed keeps the worker busy. A quick Retry can start behind it, inside its own deadline.
   - Fix: share one `cancelWorkerRequests(id)`.
2. **`sourcesChanged()` detects only deletion.** `AnswerModel.swift:~230`.
   - Its doc comment says "(edit, deletion)", but it compares only the live meeting set.
   - An edit after delivery leaves a finished answer and its chips shown as current, with no generation comparison. The T115 doc says only deletion, so the comment is wrong or the code is incomplete.
   - Fix: compare `contextGenerations` against the evidence generations.
3. **Unchecked streamed text is visible while streaming.** `App/Library/AskAnythingView.swift:~274`.
   - It is labelled "checking it against the sources next", and it is cleared on timeout, clarification, stale and failure. That is honest.
   - Text from a meeting deleted mid-stream stays on screen until the post-check (`fresh`) runs, which is at most the 15 s deadline. Consider buffering the text until it is checked, or say this limit in the qualification.
4. **The retriever's duplicated fallback planner has diverged.** `Contextual/ContextualRetriever.swift:~283` (`QueryPlanner_fallback`).
   - It lacks `QueryPlanner.fallback`'s `commonCapitalized` filter, so "What happened Monday?" treats "Monday" as a person.
   - The effect is small because role mentioned with resolution unknown only adds no guidance. It should still reuse one implementation.
5. **`QueryPlan.validated` person grounding is a substring test.** `Domain/Search/ContextualSearch.swift:~144`.
   - `haystack.contains(name)` lets a planner-invented "Al" or "Ann" pass because "also" or "annual" contains it.
   - It cannot widen scope, but it can invent a person constraint. Use a word-boundary match, as `containsWord` does in the retriever.
6. **The encoder stays resident, about 0.75 GB, beside ASR during recording.** `InferenceWorker/Runtime/StageRunner.swift` (`encoder()`), documented in `docs/decisions/models/0003-search-encoder.md`.
   - 8 and 16 GB machines are unmeasured, which the qualification admits.
   - Consider unloading the encoder at record start or after a short idle period.
7. **v7 migration robustness.** `Storage/Schema.swift:~213` (`rechunkAll`).
   - One undecodable meeting row throws inside the migration. The transaction rolls back and the library fails to open on every launch, so the user is stuck on v7-incapable state.
   - Chunking is derived data, so per-meeting `try?` plus a rebuild-on-demand flag would be safer.
   - A v6 app cannot open a v7 library ("newer than this app"). That is the accepted no-rollback policy, so the pre-install library backup the user plans is essential.
8. **Qualification wording.**
   - The frozen hash `76cbc4fb…6057f` is the sha256 of `Benchmarks/Contextual/heldout.json`, not `manifest.json`. `manifest.json` is `63fae9be…`. The brief says "manifest".
   - `VALIDATOR_RESULT` is still a placeholder (expected).
   - `t109-baseline.md` lists every held-out miss by ID before tuning. This is weak contamination, though no tuning log uses the held-out set.
   - The T116 harness files and result folders are uncommitted. Commit them before install.

## What I verified

- **Tests.** `swift test --scratch-path .build-alt --filter "Context|Chunker|DateResolver|ConstraintResolver|Answerer|ModelPack|Storage"` passed in full: 8 test runs, about 116 passing tests, 0 failures.
- **Qualification traceability.**
  - I recomputed the merged grades from `t116-grades-{opus,sonnet,merged}.json`.
    - Answer, qualify and partial: 11 correct, 13 partial, 21 wrong (n=45).
    - Abstain: 13 of 14.
    - Clarify: 2 correct, 1 partial, 1 wrong.
    - Wrong-person: h22, h23, h26 and h29. Wrong-period: h11 and h38. Unsupported claims: 13.
  - There are exactly 7 grader disagreements (h24, h25, h28, h30, h34, h47, h61), and the merged grade is the lower one in every case.
  - Retrieval (40/46, paraphrase 21/25, person/date 14/14) matches `retrieve-report.md`.
  - Terminal 63/63, max 6.0 s, and 39 citations (12 answered plus 27 partial) match `summary.md`.
  - `cold-runs.jsonl` has 180 lines, consistent with 20 runs of 9 steps.
  - The R1, A1, A2, A4 and A5 misses are reported as misses, and no target was relabeled.
  - `heldout.json` is unchanged since f65543e (no diff from T109 to HEAD).
- **Scope, date and deletion.**
  - `scopeSQL` (`Storage/Search/ContextIndex.swift`) applies deleted, meeting, folder and date filters in SQL before any vector is read.
  - FTS candidates are restricted to the same meeting set.
  - Chunks exist only through `rechunk`, which runs from `reindex` and the `upsertMeeting` tombstone. The migration uses the same `applyingTextEdits` as `reindex`.
  - Deletion removes chunks, state and orphan vectors in the same transaction.
  - `publishContextVectors` publishes only for hashes a current chunk holds.
  - `secure_delete=ON` and the WAL truncate are in place.
  - Generations are checked before prompting and before delivery.
- **15 s deadline.**
  - There is one deadline from submission, never reset. The watchdog fires at 14.25 s and the answer call is bounded by the time remaining.
  - Recording gives an immediate "unavailable", and recording start cancels an in-flight attempt.
  - Timeout clears the text. Retry gives a fresh attempt with its own 15 s.
- **Identity.** Self resolves only through a "Me" or account-name speaker. An unmapped self becomes neutral "each speaker" wording plus a post-check (see must-fix 1). Ambiguous speaker names ask for clarification. Anonymous speaker labels are kept per meeting. The planner cannot add the user unless the question has I, me or my.
- **Planner safety.** `validated` clamps sizes, drops group words, requires `meetingTime` to be a substring of the question, and the plan carries no scope. Dates are resolved by `DateResolver`, and the plan's time phrase cannot widen the UI scope.
- **Dependencies and network.**
  - `Package.swift`: Storage depends on Domain only. MeetingAccess depends on Domain, Storage and Export. Contextual depends on Domain and Storage, with model calls injected.
  - There is no `URLSession` or URL code in the new paths.
- **Packaging and installed app.**
  - Pack 0.1.2 is the 0.1.1 manifests plus the encoder, pinned by revision `370f27d7…` and sha256 `06507c7b…e439` (639,150,592 bytes). `App/Resources/default-model-pack.json` is identical to 0.1.2.
  - Installer reuse (`reusableFile`) matches on size, then verifies the sha256, then APFS-clones, and falls back to download on any mismatch.
  - `LocalModelRegistry.state()` reads the installed active pack, not the bundle, so an installed 0.1.1 pack keeps transcription working. The encoder is optional (`searchModelMissing` offers a Download), so existing transcription is not broken.
  - `ContextualEncoder.weightsSHA256` is hard-coded and matches the pack.
- **Schema.** v7 adds four new tables, with no changes to existing tables. The v6 to v7 test passes. For a library that has never been through v6, `rebuildSearchIndex` re-chunks idempotently.
- **Loading UI.** The code shows a still ring under Reduce Motion, a VoiceOver label with a Cancel action, and Esc as `cancelAction`. Animation exists only inside `.working` and `.waiting`, so it ends at the terminal state. I did not run the `ui-render-ask` render.

## Not verified

- I did not re-run the benchmarks, the packaged self-tests, `check.sh`, the capture-under-load run or `ui-render-ask`. I checked their recorded outputs only.
- A real cold disk read, 1,000-meeting libraries and 8/16 GB machines remain unmeasured, as the qualification states.
