# T113: local question interpretation with validated people and date constraints (2026-11-06)

## Pipeline

1. **Plan (model, `Notes/Answer/QueryPlanner.swift`, plan-v1):** Qwen3-4B-Instruct (answer context) with a GBNF grammar
   produces `{queries ≤ 3, terms ≤ 6, people ≤ 4 {name, role speaker|mentioned|self}, time, subquestions ≤ 3, intent,
   exhaustive}` (≤ 200 tokens). Queries are phrased as things someone might have *said* (spoken synonyms). The question
   and earlier turns are marked as data; the plan has no field for SQL, tools, paths or scope, so nothing a question
   says can widen the UI scope. Worker request `.plan(PlanRequest)` → `.plan(PlanResponse)`.
2. **Validate (`QueryPlan.validated`):** clamps counts/lengths, drops the time phrase unless it occurs in the question,
   drops people whose names aren't in the question or follow-up context, maps I/me/my to the user (and adds the user
   whenever the question says I/me/my), drops group words (we/team/they).
3. **Resolve deterministically:** `DateResolver` (frozen T109 rules: calendar vs rolling weeks, today/yesterday/this
   week/month, weekdays, month-day, DST-safe, topic dates never filter); a follow-up's own time phrase replaces the
   previous one, otherwise it inherits it. `ConstraintResolver` + `MeetingStore.nameDirectory/mentions`: a person is a
   *speaker* only if a current shown speaker name matches (first-name match allowed; two different matches →
   *ambiguous*); otherwise *mentioned only* (attendee or named in text) or *unknown*; "Speaker n" names that label;
   I/me/my is *self mapped* only where a speaker is shown as "Me" (or the account's full name) in every meeting in scope,
   otherwise *self unmapped* (answers qualify by speaker label).
4. **Fallback:** if the model output doesn't parse (or planning exceeds `ContextualLimits.planningBudget`, enforced by
   the orchestrator), `QueryPlanner.fallback` gives a constrained plan (capitalized names, I/me/my) and the result is
   labeled; explicit person/time constraints are never dropped because dates and people are resolved from the question.

## Evidence

- `Tests/Contract/DateResolverTests.swift`: the user's examples (last week = Oct 26 00:00 −04:00 → Nov 2 00:00 −05:00
  across the DST change; "in the last week" rolling from Oct 30 17:00 −04:00; today), boundary meetings (Sun 23:30 in,
  Mon 00:30 out, Sun Oct 25 22:00 out), a 25-hour Sunday, Monday/Sunday request days, month-day with year rollback;
  topic dates (planning for 2027, next quarter, due on Friday, by today, for this week's launch) never filter.
- `Tests/Contract/ConstraintResolverTests.swift`: speaker / mentioned-only (attendee, text) / unknown are distinct; two
  Andrews are ambiguous, "Andrew Kim" resolves; I needs "Me" in every meeting (partial mapping stays qualified); a
  speaker literally named "Me" isn't matched as a person; follow-up dates inherit or are replaced; a planner time phrase
  absent from the question is ignored; a name the model invented never becomes a constraint; pronoun/group/label
  handling.
- Dev set, real model (`amaranth-bench ctx-eval plan`, `Benchmarks/Results/ctx-t113-dev/plan-report.md`):
  **meeting-date constraint correct 55/55**; planner **p50 1.15 s, p95 1.63 s, max 2.31 s** (warm; within the 4.5 s
  planning budget); 1 fallback in 55. People: named speakers (Omar, Maria, "Speaker 2") resolve as speakers; names
  that only appear in speech (Tomas, Rosa, Sam) resolve as mentioned-only, so "what did Rosa say" is answered as
  "Rosa was mentioned…" unless she is a shown speaker; dev25 (a "Me" speaker) resolves self-mapped, the other I/my
  questions self-unmapped.
- Not in normal logs: plan contents. The harness writes plans to results for review only.

Remaining for T114/T115: using the constraints in retrieval (date filter before candidates, speaker attribution in
ranking and prompt), clarify/qualify wording, and the planning deadline.
