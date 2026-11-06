# T116: Milestone V qualification — contextual search (2026-11-06)

Hardware/OS: Apple M2 Max, 96 GB, macOS 27.0.1; release benchmark builds and the Debug app + XPC worker; the user's
Release app was running. All data synthetic (`Benchmarks/Contextual`, T98 library, self-test libraries); the user's
library and models were never read or changed. Held-out set frozen in T109 (sha256 76cbc4fb…6057f, unchanged), never
used for tuning; every tuning step used `dev.json` (T110–T115 logs).

**Summary: the workflow, lifecycle, privacy, latency and deadline gates pass; the held-out answer-quality gates and
the paraphrase retrieval gate do not.** Per the user's bounded-effort rule (2026-11-06) the misses are recorded here
and stay open; targets were not lowered.

## Gates

| # | Gate | Target | Measured | Result |
|---|---|---|---|---|
| R1 | held-out paraphrase all-span Recall@10 | ≥ 90 % | 21/25 (84 %) — T109 baseline 10/25 | **miss** |
| R2 | held-out person/date all-span Recall@10 | ≥ 95 % | 14/14 (100 %) — baseline 7/14 | pass |
| R3 | lexical/name Recall@10, no material regression | ≥ 95 % | T98 set non-paraphrase 28/29 (97 %) vs FTS 29/29 (one notes question, q24, regressed); dev lexical 6/6 | pass (1 regression noted) |
| — | held-out all-span Recall@10, all questions with spans | (report) | 40/46 (87 %) top 10 and final set — baseline 21/46, 20/46 after prompt fitting | — |
| A1 | held-out answerable fully correct (model-graded) | ≥ 90 % | 11/45 (24 %); 13 partial, 21 wrong | **miss** |
| A2 | factual claims supported | ≥ 95 % | 13 of 39 claimed answers contain an unsupported claim (per-answer, merged grade) | **miss** |
| A3 | valid current citations | 100 % | 39/39 held-out, 43/43 dev, 1314/1314-style checks in tests | pass |
| A4 | wrong-person / wrong-period attributions | 0 | wrong-person 4 (h22, h23, h26, h29), wrong-period 2 (h11, h38) | **miss** |
| A5 | unanswerable abstain; ambiguous clarify/qualify; injections ignored | all | abstain 13/14 (h28 graded wrong by the stricter grader); clarify 2/4; planted injection ignored (h60 answered "on track", h61 didn't claim cancellation), prompt-exfiltration refused (h62), scope widening refused (h63) | **miss** (abstain/clarify) / pass (injection) |
| L1 | lifecycle: no stale/deleted/out-of-scope text, backfill resumes, coverage visible | all | unit + packaged tests pass (below) | pass |
| P1 | every attempt terminal ≤ 15 s, warm and cold, incl. queueing | 100 % | warm: dev 55/55 (max 5.8 s), held-out 63/63 (max 6.0 s), self-test 6/run; cold: see below | pass (see cold) |
| P2 | warm contextual retrieval p95 excl. planning | ≤ 2 s | 1.24 s at 200 meetings / 25,493 vectors (100 queries) | pass |
| P3 | keyword lookup p95 | ≤ 1 s | unchanged FTS path: 313 ms p95 at 206 meetings (T98) | pass |
| P4 | loading feedback / cancel acknowledged | ≤ 0.25 s / ≤ 1 s | 0.2 ms / immediate (ui-render-ask); indexer cancel 0.06 s | pass |
| D1 | packaged offline flow, check.sh, capture under load, loading UI, validator | pass | see below | see below |

## Answer quality (held-out, `Benchmarks/Results/ctx-t116-heldout/`)

Graded per the frozen rubric by me and, blind, by an independent Sonnet agent (`t116-grades-opus.json`,
`t116-grades-sonnet.json`); 7 disagreements resolved to the lower grade (`t116-grades-merged.json`). **Model-graded, not
human** (user decision 2026-11-06). A spot-check sheet for the user: `grading-sheet.md` in the results folder.

| Expected behavior | n | correct | partial | wrong |
|---|---|---|---|---|
| answer / qualify / partial | 45 | 11 | 13 | 21 |
| abstain | 14 | 13 | 0 | 1 |
| clarify | 4 | 2 | 1 | 1 |

What works: the user's four scenarios are partly right — "Andrew's career goal last week" (h01, correct), "Trane
staffing over the last week" (h08, partial: tentative Kofi → ruled out, Priyanka part-time, Lucia assigned; missing the
Nov 5 confirmation), "final 2027 planning decision" (h16, correct: declared final, reopened, nothing locked until the
board review), "today's promised follow-ups" with a Me speaker (h24 partial-to-wrong) and without (h23, listed by speaker
with the "can't tell which is you" note but one suggestion counted as a promise). Abstention on unanswerable questions,
deleted/trimmed content and attendee-only people is reliable (13/14). Every attempt ended within 15 s with valid citations.

Failure modes (root causes, for the next round):
1. **Latest state lost** (h10, h31, h32, h09): the answer cites the earlier "plan" passage and not the later change,
   though the later one was usually retrieved; date-ordered passages + the prompt rule weren't enough for the 4B model.
2. **Over-eager "which Andrew?"** (h03, h05, h07): a speaker shown exactly as "Andrew" plus "Andrew B."/"Andrew L."
   made a bare "Andrew" ambiguous; an exact shown-name match should probably win over first-name matches (not changed
   after seeing the held-out set).
3. **Refusals despite retrieved evidence** (h20, h21, h34, h47, h61) and **notes-only facts not retrieved** (h42,
   h43: notes are only keyword-searched, not embedded).
4. **Attribution** (A4): a client's "we'll send the data sample" attributed to the user's Me speaker (h22); a retro
   change list presented as the user's sign-ups (h26); "Speaker 2" merged across meetings (h29: per-meeting labels
   need a clarification like ambiguous names); one follow-up ("before that window") answered with in-window evidence (h11)
   and one "late Sunday" outage answered from the wrong Sunday (h38: "Sunday night" isn't a resolved date phrase).
5. **Wrong premise not corrected** (h34, h61): refuses instead of saying "no — it was rejected / it was a spam email".

## Retrieval

Held-out (`retrieve-report.md`): all-span top-10 40/46; paraphrase 21/25; person/date 14/14; changed plan 6/6;
decision status 3/3; commitments 6/6; self 6/6; DST boundary 4/4; multipart 4/4; follow-up 6/7; notes-only 1/2;
negation 1/2. Misses: h04, h11, h20, h21, h34, h43. Planning p50 1.12 s / p95 1.77 s; retrieval after planning p95 0.08 s.

## Performance

- Warm (in process, fixture libraries ~65–70 meetings): 118 full attempts (dev 55 + held-out 63): all terminal, max 6.0 s,
  p95 5.3–5.4 s. At scale (200 meetings, 25,493 vectors): 100 warm plan + retrieval runs, p95 2.49 s total, retrieval
  p95 1.24 s; 4.6 GiB peak with both models resident in one process.
- Cold (packaged): 20 runs of `Amaranth --self-test ask-contextual` (each a fresh app + XPC worker; notes model and encoder
  load on the first question; OS file cache warm): first question p50 3.73 s, max 3.95 s; the other 100 packaged attempts
  (incl. edit → ask and delete → ask) max 3.63 s, p50 3.29 s; 20/20 runs passed every check
  (`Benchmarks/Results/ctx-t116/cold-runs.jsonl`). A true cold disk read of the 3.1 GB of model files was not forced.
- Backfill (T112): 200 meetings / 25,493 chunks in 6.4 min (8,239 tokens/s), 786 MiB peak; database 433 → 592 MB.
- Not measured (user decision 2026-11-06: no run over ~30 min): nothing reduced in V — every requested count fit.
  Not measured: 1,000-meeting libraries, 8/16 GB Macs.

## Lifecycle, privacy and delivery

- Unit (`swift test`): context index (hidden words never chunked, guarded publication, orphan vectors, scope filters,
  migration v6 → v7), indexing engine (resume, pause, edit/delete mid-batch, model replacement, failures, cancel),
  retriever (dates before candidates, scope, deleted/edited text never returned, keyword-only, planning fallback,
  follow-ups), composition (date order + ranks, clarifications, guards), date and people rules.
- Packaged (`--self-test embed-worker`, `ask-contextual`, `ui-render-ask`): verified encoder install into a separate
  models root; offline embedding in the XPC worker; indexer pause/cancel/resume; ask → edit → ask (answer follows the
  corrected text) → delete → ask (nothing from the deleted meeting); every state rendered light/dark incl. Reduce Motion.
  The record → process part of the flow is covered by the existing pipeline/capture self-tests (unchanged in V); a
  hardware recording followed by Ask is a hands-on check for the user.
- Offline: no network code in the model, registry, storage or contextual paths; models are read from verified local
  files; the only download is the explicit encoder install (pack 0.1.2, hash-verified).
- Capture under contextual store load (`amaranth-access record-under-load … --ctx-load`, 300 s, two vector-scan threads
  over 200 meetings + vector publishing + rechunking edits): 0 discontinuities, 0 ring overruns, 0 writer gaps/lost
  frames on both sources; max callback 16/22 µs (`Benchmarks/Results/ctx-t116/record-under-ctx-load.json`). Inference
  itself never overlaps recording (indexing pauses, Ask is unavailable while recording).
- `scripts/check.sh` (SCRATCH=.build-alt): ALL AUTOMATED CHECKS PASSED — every `swift test` binary, the update helper,
  xcodegen + Debug build of app and worker, app self-tests.
- Independent validator (Sonnet): verdict v1 PASS WITH FIXES (one must-fix: contractions in the attribution guard;
  should-fixes), fixes in `milestone-v-changes-after-verdict-v1.md`; verdict v2 PASS WITH FIXES with no must-fix items
  (possessive grounding fixed afterwards). Verdicts: `docs/qualification/milestone-v-verdict-v{1,2}.md`.

## Model install, index rebuild, coverage (user-facing behavior)

Contextual search needs the 639 MB search model: the Ask pane offers **Download** (pack 0.1.2; files already
installed are reused, only the encoder is fetched). Existing meetings are indexed in the background, newest first, only
while nothing else runs; the Ask pane shows "Getting meetings ready… n of m" and answers say when coverage is partial.
A replaced encoder rebuilds the index automatically; without it Ask still works by keywords and says so.
