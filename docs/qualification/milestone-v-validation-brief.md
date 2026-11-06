# Milestone V validation brief (contextual search, T109–T116)

Spec: `docs/decisions/0010-contextual-search-spec.md`. Tasks: `docs/implementation-tasks.json` (T109–T116).
Commits: T109 f65543e, T110 1ecba0a, T111 96c0a5f, T112 4a03606, T113 68db02f, T114 5981d7d, T115 1728dea, T116 (this).

User decisions for this run (2026-11-06): held-out answers graded by me + a blind Sonnet agent ("model-graded, not
human"); a failing gate gets ~3 fix rounds, then is recorded and kept open (targets never lowered); no measurement run
over ~30 min; after a validator pass, back up the real library and install the Release build locally (no publish).

## What to check (adversarially)

1. **Honesty of the qualification** (`docs/qualification/milestone-v/t116-qualification.md`): every number traceable to
   `Benchmarks/Results/ctx-t1*/` files; misses (R1, A1, A2, A4, A5) reported as misses; no target relabeled; held-out
   set unchanged since T109 (`Benchmarks/Contextual/manifest.json` sha256) and not used for tuning (tuning logs in
   t110/t114/t115 docs cite dev only).
2. **Scope/privacy/lifecycle invariants** (code + tests): UI scope and resolved meeting dates applied before candidates
   (`Contextual/ContextualRetriever.swift`, `Storage/Search/ContextIndex.swift` `scopeSQL`); hidden/deleted/trimmed text
   never chunked or returned (`reindex` → `rechunk`, tombstone in `upsertMeeting`, purge); guarded vector publication;
   no inference dependency in `Storage` or `MeetingAccess` (Package.swift); no network code in new paths; the planner
   output can't widen scope or invent people/dates (`QueryPlan.validated`, `ConstraintResolver`).
3. **15-second deadline** (`App/Library/AnswerModel.swift`): one deadline from submission, never reset; watchdog;
   unchecked streamed text never left as the answer; recording → immediate unavailable; stale checks; cancel paths.
4. **Identity rules**: I/me/my only via a "Me" speaker; unmapped → neutral question + post-check
   (`Presentation/ContextualAsk.swift`); speaker vs mentioned vs attendee.
5. **Packaging**: model pack 0.1.2 pins (`Models/Packs/amaranth-default-16gb-0.1.2.json`, `docs/decisions/models/0003`),
   installer reuse (`ModelInstaller.reusableFile`), notices; the bundled pack JSON; library schema v7 migration.
6. **Loading UI** (`App/Library/AskLoadingView.swift`, renders via `--self-test ui-render-ask --render-dir <dir>`):
   on-theme, Reduce Motion still variant, VoiceOver label, Cancel, never animates forever.
7. Run `swift test --scratch-path .build-alt --filter "Context|Chunker|DateResolver|ConstraintResolver|Answerer|ModelPack|Storage"`
   and anything else you think necessary. Do not touch the user's library, models or preferences.

## Known limits (stated, not hidden)

Answer-quality gates missed (see qualification); notes not embedded; "Sunday night"-style phrases not resolved;
1,000-meeting and 8/16 GB not measured; hardware record → Ask is a hands-on check.
