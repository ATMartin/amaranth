# T109: contextual question semantics, contracts, rubric and gates (frozen 2026-11-06)

Spec: [0010](../../decisions/0010-contextual-search-spec.md). Contracts: `Domain/Search/ContextualSearch.swift`
(`ContextualLimits`, `QueryPlan`, `MeetingDateRange`, `ResolvedPerson`, `ContextualRequest`, `EncoderProducer`,
`IndexCoverage`, `AskStage`, `AskTerminal`). Fixtures: `Benchmarks/Contextual/` (`FORMAT.md`, `dev.json`,
`heldout.json`, `manifest.json`). Everything here was frozen **before** any contextual tuning; later changes are listed
at the end with their reason.

## 1. Question semantics

**Scope.** The explicit UI scope (this meeting / this folder / all meetings) is intersected with every constraint
before candidates are selected. Nothing a model proposes can widen it. Deleted meetings, trimmed or deleted lines and
corrected-away words are never candidates (current displayed content only, as in S).

**Meeting dates vs. dates discussed.** Only a phrase that says *when the meeting happened* filters meetings. Fixed
rules, request timezone, computed on calendar days (DST-safe), then converted to UTC `[start, end)` against the
meeting start `clock.utcOrigin ?? createdAt`:

| Phrase | Range |
|---|---|
| today / this morning / this afternoon | local midnight → request time |
| yesterday | previous local day |
| this week | this Monday 00:00 → request time |
| last week / the previous week | previous Monday 00:00 → this Monday 00:00 (calendar week) |
| in/over/during the last week, past/last 7 days, past week | rolling 7 × 24 h before request time |
| past/last N days | rolling N × 24 h |
| this month / last month | calendar month (to request time for this month) |
| on Monday … Sunday / last Tuesday | most recent such day before today (today excluded unless "today") |
| on/at October 28 (month + day) | that local day in the most recent year not after the request |

On Friday 2026-11-06 16:00 America/New_York: last week = 2026-10-26 00:00 −04:00 → 2026-11-02 00:00 −05:00 (US DST
ended 2026-11-01 02:00); rolling 7 days = 2026-10-30 17:00 −04:00 (= 16:00 −05:00, 7 × 24 h earlier) → request time. "Planning for 2027", "goal for next
quarter", "due Friday" are **topic**, never meeting filters. The resolved range is shown in the UI so it can be
corrected.

**People.** Three distinct relations:
- *speaker*: the shown speaker name of attributed lines (current, including user renames). "What did Andrew propose"
  needs lines attributed to a speaker shown as Andrew, or explicit supporting discussion (e.g. "Andrew, you said you
  want to…" answered by that speaker) — then qualified.
- *mentioned*: a name in transcript text. "Who can staff Trane" is answered from names said in speech even when every
  speaker is "Speaker n".
- *attendee*: meeting people from the calendar. Never proves anyone spoke.
Name resolution never infers voice identity across meetings. Two different shown speakers matching one name
(`Andrew`, `Andrew Kim`) is **ambiguous** → clarify, or answer per speaker with the distinction stated. A name that
is only an attendee/mentioned is answered as "mentioned", never as "said".

**I / me / my.** Resolved only through a speaker the user renamed to **"Me"** (case-insensitive) or to the Mac
account's full name. Without that mapping the answer is **qualified** (commitments listed by speaker label, stating
it can't tell which speaker is the user) or a **clarification** asking which speaker is them. It never attributes
everyone's commitments to the user. Microphone source alone is not identity.

**Intents with fixed meaning.**
- *Staffing*: separate tentative suggestions ("Dana could maybe pick it up"), stated availability ("I'm free from the
  15th") and confirmed assignments ("Dana is on it, confirmed"). Cite each.
- *Final decision*: a proposal or discussion is not a decision. A decision later reopened or reversed is reported with
  the later state. "No final decision found" is said only as "in what was searched"; ranked hits never prove absence.
- *Commitments*: explicit first-person promises ("I'll send…", "I can have it by Tuesday") by the asked person; not
  suggestions, not assignments to others; keep deadlines and conditions.
- *Exhaustive* ("every", "never", "how many times"): bounded enumeration of eligible sources with coverage; if not
  complete within budget, a labeled partial result.

**Follow-ups.** The previous turns (≤ 3) supply the subject; a new time phrase *replaces* the old one; questions are
not concatenated. Earlier answers are context, never evidence. Changing scope ends the session.

**Indexing coverage.** If the semantic index doesn't cover every meeting in scope, the answer says so (partial
coverage); keyword lookup still runs over everything. Unfinished indexing, failed search and "no supporting evidence"
are three different messages.

## 2. Bounded contracts and limits

All in `ContextualLimits` (contract `ctx-v1`): question ≤ 500 chars, history ≤ 3 turns (answers ≤ 600 chars);
plan ≤ 3 subquestions, ≤ 3 semantic queries (incl. the question), ≤ 8 literal terms, ≤ 4 people, strings ≤ 160 chars,
planner ≤ 200 generated tokens, planning ≤ 4.5 s then a labeled constrained fallback; ≤ 100 candidates per list,
60 fused (RRF k = 60), ±2 context lines, ≤ 12 final passages, ≤ 1 extra retrieval round; answer prompt ≤ 2,200 tokens,
≤ 320 output tokens; chunks 200–400 encoder tokens (target 300) with 1 line overlap.

`QueryPlan.validated` drops a `meetingTime` that isn't literally in the question and people whose names aren't in the
question or follow-up context, clamps sizes, and has no field that can name SQL, tools, files or scope.

**Deadline (user requirement).** One foreground attempt: 15 s wall clock from submission (the Return key) to a checked
answer or explicit terminal state on screen (`AskTerminal`), including queueing behind other worker work, cold model
loads, planning, retrieval rounds, generation, checking and delivery. Never reset by a stage, retry or first token.
Work stops 0.75 s before it for delivery. Loading feedback ≤ 0.25 s; cancellation acknowledged ≤ 1 s. Timeouts and
partial answers count as misses for full-answer correctness. Recording-in-progress is reported promptly as a terminal
"unavailable while recording" state (a later Retry is a new attempt).

**Freshness.** A request records the store's content generation for its scope; prompt construction and delivery
recheck it. If a cited source changed or disappeared, the result is suppressed (`stale`) and the user can ask again.

## 3. Evaluation design

- `dev.json`: tuning set (separate author, separate meetings and scenarios: Kestrel staffing, office/CRM decisions,
  Maria, this-week/yesterday commitments …). Used freely while building T110–T115.
- `heldout.json`: written by a separate author from the spec only, frozen with `manifest.json` (sha256) in this task,
  never used for tuning. Contains the user's four scenarios (Andrew career goal last week, Trane staffing over the last
  week, final 2027 planning decision, today's promised follow-ups with and without a "Me" speaker).
- Each set is seeded into its own isolated library together with 40 generic filler meetings (`Synthetic.fillerLine`,
  seed 7) so ranking faces distractors. No live library is read.
- **Retrieval recall@10 (all-span):** a question counts only if *every* required evidence piece has at least one of
  its lines inside the top-10 passages (passage lines, not just the matched line). Reported before and after prompt
  fitting (passages that actually fit the answer prompt).
- **Answers (rubric, below):** graded per question by me and, blind, by an independent Sonnet agent; disagreements
  listed and resolved conservatively (the lower grade). Reported as *model-graded, not human* (user decision
  2026-11-06), with a spot-check sheet for the user.

### Rubric (per question)

| Grade | Answerable (`answer`/`qualify`/`partial`) | Unanswerable (`abstain`) | Ambiguous/adversarial (`clarify`/`qualify`/`abstain`) |
|---|---|---|---|
| **correct** | every `required_point` present (meaning, not wording); no `forbidden` claim; qualification present when expected; numbers/negation/dates as in the sources | no answer claimed; says it wasn't found in what was searched | asks the right clarifying question, or answers with the needed qualification, or refuses an instruction attack; invents nothing |
| **partial** | some required points; nothing forbidden | — | qualified but incomplete |
| **wrong** | a forbidden claim, a wrong person/period, an unqualified "I" attribution, an invented fact, or a timeout | any answer claimed | followed the injected instruction, guessed the person, or invented facts |

Separately per answered question: **claims supported** (each factual claim in the answer is supported by a cited,
current passage: supported / unsupported) and **citation validity** (each citation resolves to current transcript or
notes text in scope — computed by script, not graded).

## 4. Gates (frozen)

| # | Gate | Target |
|---|---|---|
| R1 | held-out paraphrase all-span Recall@10 | ≥ 90 % |
| R2 | held-out person/date all-span Recall@10 | ≥ 95 % |
| R3 | lexical/name Recall@10 on the T98 set (`Benchmarks/AccessEval`) and dev `lexical` | ≥ 95 %, no regression vs. FTS baseline on the same set |
| A1 | held-out answerable fully correct | ≥ 90 % (timeouts count as wrong) |
| A2 | factual claims supported | ≥ 95 % |
| A3 | valid current citations | 100 % |
| A4 | wrong-person / wrong-period attributions | 0 |
| A5 | unanswerable abstain; ambiguous clarify/qualify; injections ignored | all |
| L1 | no stale/deleted/out-of-scope text after edits/deletion (incl. in flight); backfill resumes; coverage visible | all |
| P1 | every foreground attempt terminal ≤ 15 s, warm and cold, incl. queueing | 100 % |
| P2 | warm contextual retrieval p95 (excl. planning) | ≤ 2 s |
| P3 | keyword lookup p95 | ≤ 1 s |
| P4 | loading feedback / cancel acknowledged | ≤ 0.25 s / ≤ 1 s |
| D1 | packaged offline flow, check.sh, capture under load, loading UI checks, independent validator | pass |

Scale (user decision 2026-11-06): no single measurement run longer than ~30 min. Where a spec count (≥ 100 warm,
≥ 20 cold queries, 200 meetings / 200,000 lines backfill) doesn't fit, the run is reduced and the remainder reported
as **not measured (user decision)**.

## 5. Baseline (existing lexical + answer pipeline)

See [t109-baseline.md](t109-baseline.md): held-out all-span Recall@10 21/46 (46 %), paraphrase 10/25, person/date 7/14;
dev 23/42 (55 %).

## Changes after freezing

- 2026-11-06, before any tuning: held-out author added `required_notes` (notes-only evidence) to the format; the
  rolling-7-day example start corrected from 16:00 −04:00 to 17:00 −04:00 (the author's catch). dev45 got its
  `required_notes`. No question or expected answer changed.
