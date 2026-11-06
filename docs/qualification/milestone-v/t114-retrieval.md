# T114: contextual evidence with hybrid search and bounded reranking (2026-11-06)

Module `Contextual` (`Contextual/ContextualRetriever.swift`): depends on Domain + Storage only; model calls are
injected (`ContextualModels`: the app's XPC worker, or in-process models in the benchmark). `Storage` and the
model-free `MeetingAccess` list/search/get contract are unchanged.

## Workflow (fixed, bounded)

1. Embed the question (and, for a follow-up, "previous question + question") and plan concurrently; planning has its
   own deadline (`ContextualLimits.planningBudget` 4.5 s) after which the deterministic fallback plan is used (labeled).
2. Constraints (T113) → `ContextFilter`: UI scope ∩ meeting-date range. The live meeting set is computed first; both
   candidate lists only ever see it.
3. Candidates: exact vector search (k = 100) per query vector — question, follow-up form, ≤ 2 paraphrases, ≤ 3
   subquestions (one foreground embedding batch); FTS retriever (k = 40) over question + literal terms restricted to the
   same meeting set; FTS transcript hits map to the chunks holding their matched lines, FTS notes lines stay notes items.
4. Weighted reciprocal rank fusion (k = 60; the lexical list weighs as much as all semantic lists together) → ≤ 60
   candidates → deterministic rerank (+0.35 for lines by an asked speaker or the user's mapped speaker, +0.35 for a
   chunk naming an asked person, +0.15 for a literal term) → ≤ 12, plus one extra round (≤ 2 chunks for each
   subquestion with no evidence in the set).
5. Context expansion from current search-index rows (±2 lines), overlapping passages of one meeting merged (≤ 30
   lines); every line carries its current citation evidence. The result records per-meeting generations (stale checks
   in T115), coverage, whether semantic retrieval ran, and stage timings. No dedicated reranker model and no approximate
   index were adopted (exact search is fast enough; see below).

Chunks gained a `Meeting: <title>` first line (chunk-v2; a rename re-chunks the meeting in the same write) so passages
carry their meeting's topic.

## Tests (`Tests/Contextual/ContextualRetrieverTests.swift`)

Date range applied before candidates (a strong match outside last week never appears); folder and meeting scope;
tombstoned meeting never returned and not in generations; deleted and corrected-away words never in passages and every
passage has current evidence; an unindexed meeting is found by keywords and coverage says partial; keyword-only mode
(no encoder) works and is labeled; a planner slower than its budget falls back within the budget and keeps the date and
person constraints from the question; asked speaker's lines rank first; a follow-up keeps its subject.

## Dev-set tuning log (dev.json only; all-span recall, 42 questions with spans)

| Round | Change | top 10 | final set | paraphrase (17) | person/date (11) |
|---|---|---|---|---|---|
| T109 baseline | shipped FTS + answer | 23 | – | – | – |
| 1 | hybrid workflow as above (chunk-v1, lexical weight 1) | 35 | 35 | 14 | 10 |
| 2 | title header (chunk-v2), follow-up query, planner jargon hint (plan-v2), lexical weight ½ of semantic | 35 | 35 | 14 | 10 |
| 3a | + meeting-level aggregation 0.5 | 32 | 32 | 11 | 9 |
| 3b | aggregation 0.15 / 0 ; name boost 0 / 0.35 | 34–35 | 35 | 13–14 | 10 |
| 3c | lexical weight = all semantic lists (**chosen**) | **35** | **37** | 14 (final 15) | 10 |
| 3d | + drop singletons ranked ≥ 10 / ≥ 20 | 35 | 37 | 14 | 10 |

Lexical 6/6 throughout. Remaining dev misses are multi-piece questions where one of two or more required pieces is
missing (dev01–dev05, dev08 staffing / ruled-out across three meetings, dev48) and one notes-only question (dev45).
Per the user's bounded-effort rule, tuning stopped after three rounds; the held-out gates are measured in T116.

## Latency

- Dev library (~65 meetings): retrieval after planning p50 0.06 s / p95 0.08 s; planning p50 1.13 s / p95 1.81 s.
- Scale library (200 meetings × 1,000 lines, 25,493 real vectors, `Benchmarks/Results/ctx-t114/scale-retrieve.txt`,
  100 warm queries): **retrieval after planning p50 1.08 s, p95 1.24 s, max 1.26 s** (gate P2 ≤ 2 s: pass); planning
  p50 1.07 s / p95 1.38 s; plan + retrieval p50 2.12 s / p95 2.49 s; process peak 4.6 GiB with both models resident.
