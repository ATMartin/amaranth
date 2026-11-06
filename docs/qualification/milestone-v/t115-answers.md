# T115: cited contextual answers, on-theme loading feedback and the 15-second deadline (2026-11-06)

## What changed in the app

- **Ask pipeline** (`App/Library/AnswerModel.swift`): Return → loading view at once (`.working(.preparing)`) → the
  contextual retriever (T114) through the XPC worker (`WorkerContextModels`: `.plan`, foreground `.embed`) → the
  composer → the answer model → deterministic checks → a terminal state. One deadline: 15 s from submission minus
  0.75 s delivery margin, enforced by a watchdog that cancels the worker request and shows **timed out** (unchecked
  streamed text is cleared, never left as the answer); planning gets ≤ 4.5 s and never past deadline − 8 s; the answer
  request's timeout is the time left.
- **States**: working (preparing / searching / reading / answering), waiting (transcription, waited out only while ≥ 9 s
  remain, else an explicit "ask again in a moment"), unavailable (recording in progress: immediate, with Retry; notes
  model missing), streaming (labeled "still writing — checking it next"), done (answered or labeled partial),
  clarification, no evidence ("doesn't mean it was never said"), stale, timed out, failed. Retry starts a new attempt.
- **Grounding** (`Presentation/ContextualAsk.swift`, prompt answer-v3): passages go to the model in date order with
  dates and ranks; fitting to the 2,200-token budget drops the worst-ranked passage (never simply the latest) and
  citations are mapped back to the request's passages. Deterministic "search facts" tell the model the dates searched
  and who is a speaker / only mentioned / the user. Rules for latest decision state, proposals vs final decisions,
  staffing suggestions vs availability vs assignment, and commitments. Lexical support floor 0.25 → 0.18 (paraphrased
  answers; the rubric judges support).
- **Identity guards**: with the user unmatched, the model sees "each speaker" instead of I/me/my; any first-person or
  "you" attribution in the answer becomes a clarification (`attributionViolation`). A model-proposed "self" without
  I/me/my in the question is dropped. With a "Me" speaker the model sees "Me (the user)" and is told meetings without
  one can't be attributed. Ambiguous asked speaker → clarification naming the candidates.
- **Freshness**: generations of the passages' meetings are checked before prompting and of the cited meetings before
  delivery → stale; a finished answer whose cited meetings were deleted is marked stale on the next library reload.
- **Follow-ups**: only a follow-up (`AskFollowUp.isFollowUp`) inherits the previous subject and dates; any other
  question in the session starts fresh (found by the packaged self-test: an unrelated question had inherited "today").
- **UI** (`AskAnythingView.swift`, `AskLoadingView.swift`): the ring-of-seeds loader (rose/sage seeds orbiting a cream
  heart, gentle pulse; Reduce Motion: still ring; VoiceOver: one "Answering: <stage>" element with a Cancel action;
  Cancel button with Esc) and stage copy ("Looking through your conversations…", "Putting the answer together…"); the
  answer with citation chips, notes (dates searched, index coverage, keyword-only, who "I" is), "Passages read (n)"
  with cited ones marked, and the keyword list relabeled **Exact word matches**. `SearchModelNotice` offers the explicit
  encoder download (pack 0.1.2; only the encoder is fetched) and shows indexing progress.

## Evidence

- Unit: `Tests/UI/ContextualAskTests.swift` (date order + ranks, clarification, honest no-evidence, pronoun rewrite,
  attribution guard, guidance and notes), `Tests/Notes/AnswererTests.swift` (rank-aware fitting maps citations, search
  facts in the prompt), plan validation (no self without I/me/my).
- `Amaranth --self-test ui-render-ask --render-dir <dir>`: renders every state, light/dark, loader at each stage animated
  and Reduce Motion (32 images); loading state shown 0.2 ms after `ask()` (< 250 ms), cancel acknowledged immediately
  (< 1 s).
- `Amaranth --self-test ask-contextual --model-dir ModelStore --models-root <dir>` (packaged worker, real notes model and
  encoder from a separate verified install, synthetic library indexed by the real indexer): cold first question 4.54 s,
  then 2.9–3.6 s; staffing over the last week (confirmed assignment vs earlier tentative mention), a proposal last
  week, today's commitments listed by speaker with the "can't tell which speaker is you" note, a reopened decision
  reported as not final; after a correction the answer uses the corrected name; after deletion nothing from that
  meeting is read or cited.
- Dev set, whole pipeline in process (`amaranth-bench ctx-eval answer`, `Benchmarks/Results/ctx-t115-dev/`): **55/55
  terminal within 15 s** (warm max 5.8 s, p50 3.9 s, p95 5.4 s), 0 timeouts, citations valid 43/43; abstain-expected
  9/9 abstained; 3 of 35 answerable questions refused despite retrieved evidence (dev27, dev38, dev48). Not graded
  here: the held-out set is graded (model-graded, user decision) in T116.
- Tried and reverted: ±1 context line (all-span in cited passages 28 vs 29).
