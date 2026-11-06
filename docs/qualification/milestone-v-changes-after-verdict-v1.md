# Milestone V: changes after verdict v1 (PASS WITH FIXES)

Must-fix
1. `attributionViolation` now matches contractions directly after the pronoun ("I'll", "you'll", "we'd", "I've", curly
   apostrophes too) — `Presentation/ContextualAsk.swift`; tests added in `Tests/UI/ContextualAskTests.swift`.

Should-fix applied
- Timeout cancels the plan and query-embedding requests too (`AnswerModel.timeOut`).
- `sourcesChanged()` marks a shown answer stale on edits as well as deletion (generations of the cited meetings vs those
  the answer was read at).
- The retriever's fallback plan skips day/month names (no "Monday" person).
- `QueryPlan.validated` grounds people by whole words ("Al" isn't grounded by "also"); test added.
- `rechunkAll` (v7 migration) skips an undecodable meeting row instead of failing the migration.
- Brief wording: the frozen hash is `heldout.json`'s sha256 as recorded in `manifest.json`.

Not changed (stated limits)
- Streamed text stays visible, labeled "still writing — checking it against the sources next", until the checked
  answer or a terminal state replaces it (≤ 15 s); a deletion mid-stream ends in "stale".
- The encoder stays resident beside ASR (≈ 0.75 GB); 8/16 GB Macs remain unmeasured (spec: not claimed).
- A v6 app can't open a v7 library: the install step backs up the library first (as for v6).
- `t109-baseline.md` lists held-out miss IDs (baseline reporting before tuning); no tuning used held-out data.

After verdict v2 (PASS WITH FIXES, no must-fix): whole-word grounding splits on every non-alphanumeric so possessives and
sentence-final names ("Al's team", "Ask Al.") ground; test added. The duplicated fallback word list stays (cosmetic).
