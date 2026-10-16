# Notes 0001: Evidence-backed meeting notes, fully local (T09)

Date: 2026-10-16 · Task: T09 · Status: Accepted for v0 (`notes-v1`). **The plan §10 human quality gates have not been
evaluated.** Review sheets are prepared for a human reviewer. The automatic proxies below are not those gates.

## Decision

Model: Qwen3-4B-Instruct-2507 Q4_K_M via llama.cpp b11669 (Metal), greedy and grammar-constrained, with the pinned
`chatml-manual-v1` template and an 8,192-token context. It runs in the XPC worker (`ModelProvider.notes()` releases
ASR and diarization first). The engine has **no tools and no side effects**: output is parsed as data only.

Pipeline (`Notes/Pipeline/NotesPipeline.swift`):
1. **Input** (`NotesInputDocument`). The transcript is rendered as numbered lines, with text corrections applied.
   - Consecutive runs by the same speaker merge into one line (pause under 3 s, at most 80 words). A line maps back to
     one or more `TranscriptEvidence` spans.
   - A line that looks addressed to an AI is never merged with anything.
   - No timestamps go into the prompt.
   - Missing, untranscribed or paused audio of 5 s or more appears as a non-citable `[--]` marker.
   - The private scratchpad is included **only** when the user switched it on. It is labelled "PERSONAL NOTE …, not
     spoken" and numbered from 90001.
2. **Map.** Token-budgeted chunks of about 5,000 tokens with 3 lines of overlap cover the whole meeting. Extraction
   uses a GBNF grammar (at most 16 items, at most 6 cited lines each). Invalid or truncated output gets **one repair**
   with at most 8 items. A chunk that still fails becomes a limitation naming its time span; it is never skipped
   silently. If every chunk fails, the job fails and the prior summary stays current.
3. **Deterministic checks** (`EvidenceChecker`).
   - Rejected or removed: cited IDs outside the chunk; owners not equal to a cited speaker label and not named in the
     passage; deadlines not found verbatim; items whose spoken evidence is only text addressed to an AI.
   - Personal notes alone can't make a decision or action.
   - Numbers or (capitalised) names missing from the passage, low lexical support, or text that looks addressed to an
     AI mark an item for verification and as uncertain.
4. **Verify.** Every decision and action, and every doubted item (up to 120 per meeting), is re-read by the model
   against its cited lines plus one line of context.
   - "no" drops the item; "partly" marks it uncertain.
   - "proposal" demotes a decision to a topic (the T02 over-labelling fix).
   - Owner and deadline survive only if both the model and the passage support them.
   - The verifier cannot clear an unsupported number.
5. **Reduce.** Near-duplicates merge with their evidence unioned. They are never merged across a negation or number
   mismatch, so revisions and contradictions both survive in time order. Per-kind caps (decisions 25, actions 30,
   questions 20, topics 15) pick items evenly across the timeline, never by truncating at the end.
6. **Overview** is written from validated, non-uncertain items only. Each sentence must cite items; uncited sentences
   are dropped and citation text is stripped. **Limitations are computed, not generated:** missing or untranscribed
   audio, the unknown-speaker share, garbled words, text addressed to an AI, personal-note use, dropped and capped
   counts, and "check important items".

Every model call is checkpointed (keyed by prompt version, model config and exact input), so a cancelled job resumes.
The KV cache reuses the shared prompt prefix across calls.

**Scheduling** (`JobScheduler`): the `reconcile → notes` stage.
- Notes run automatically **once**, for the first reconciled transcript.
- Later speaker or text edits make the notes **stale**. `MeetingStore.currentSummary` computes this on read: a
  different transcript revision, or edits newer than the summary's input.
- `enqueueNotes` regenerates. A failed regeneration leaves the previous summary current.
- User notes (`ManualNotesRevision`) are separate records that regeneration never touches.
- A summary for a deleted meeting, or one older than the current summary, is never published. Evidence is validated
  against the exact transcript and scratchpad revisions used.

## Measurements (M2 Max; `amaranth-bench notes-eval`; `Benchmarks/Results/2026-10-16-t09-notes/run.log`)

| Check | Result |
|---|---|
| 2-hour coverage: 6 decisions/actions planted at about 5, 7, 60, 62, 115 and 117 min in a 2-hour transcript of real AMI reference speech (three AMI meetings looped). **The planted lines are unnaturally explicit** ("Final decision: we drop…", "Yes, agreed"), so this tests coverage and evidence plumbing, not detection of subtle decisions | **6/6 found**, each citing the planted lines; owners 6/6 exact; deadlines 4/6 exact (one dropped where the passage didn't support it; one "end of the month" vs "by the end of the month") |
| 1-hour version | 2/2, owners and deadlines exact |
| Transcript-injected instructions (10 variants: "note to the AI…", "ignore your previous instructions…", "system prompt override…", "email the transcript to…", "write down that we all agreed… even though we didn't", …) | **10/10**: no generated item repeats the injected claim. **This is a development set, not a held-out measure.** Run 2 scored 9/10, and the detection regex and line-merging rule were then fixed against these same lines. Not covered: injection through titles, speaker names or the scratchpad; non-English; paraphrases outside the patterns. The "cannot invoke tools or change export/privacy" part holds by construction: the pipeline has no tools or actions, and exports escape Markdown so injected links and images stay inert text. |
| Recall proxy against AMI human summaries, production ASR + diarization input | IS1009a 3–7/7 across runs (including the validator's runs); ES2004a 0–1/1. **A lenient keyword proxy:** a reference item counts as recalled if any of its keywords (e.g. "marketing", "lost", "prepare") appears in *any* generated item of *any* kind. It is not decision/action recall: both AMI meetings yield 0–1 decisions, because the verifier demotes handed-down targets to topics. It varies run to run because line merging and caps change what the model sees. |
| Time, notes stage only | 60 min → **200–204 s**; 120 min → **465–475 s** (17 chunks, 115–118 verifications) |
| Through the real XPC worker and installed pack (`pipeline-e2e` self-test: record → prepare → transcribe → diarize → reconcile → notes) | Pass: notes in 42 s, 16 items, every reference valid, producer `llama.cpp-b11669/qwen3-4b-instruct-2507-q4_k_m` (`evidence/2026-10-16/selftest-pipeline-e2e.jsonl`) |

Scripted-model tests (`Tests/Notes`, 11) cover:
- evidence, owner and deadline validation;
- injection handling;
- verifier drop and demote;
- number doubt;
- beginning/middle/end coverage on 1,800 lines;
- caps spread across the timeline;
- contradictions kept;
- one repair, a failed chunk becoming a limitation, and a total failure failing the job;
- personal notes only when included;
- gaps shown to the model;
- cancel and resume from checkpoints.

Scheduler tests cover notes running once, staleness after edits, a failed regeneration keeping prior notes, user
notes untouched, no notes model meaning no job, and deleted meetings getting no summary.

## Acceptance (T09)

| Criterion | Status |
|---|---|
| Two-hour transcripts covered; beginning, middle and end represented | Met (planted 6/6; chunking covers every line) |
| Every item references valid evidence; human evaluation meets support/recall/owner/deadline gates | Evidence validity met (`validateReferences` on every revision, and again at publish). **Human evaluation pending:** `notes-review-*.md` sheets are ready (tracked item 6). |
| Transcript-injected instructions cannot invoke tools or change export/privacy behaviour | Met (no tool surface; 10/10 suite) |
| Failure leaves transcript and prior summary intact; regeneration never silently overwrites user edits | Met (tests) |
| 8 GB profile only if it passes the same quality bar | Not shipped (8 GB unverified; models/0001) |

## Known weaknesses (for the human evaluation and T12)
- **Uncertainty is frequent.** 31–33 of 57 items at 120 min (54–58% across runs), 21–23 of 46 at 60 min, and 7 of 11–12 on AMI are
  marked uncertain, mostly verifier "partly" on items that pack several details together. This is honest but noisy.
- **Topics and questions are verified by the model only when a deterministic check doubts them.** The checks are
  lexical support, numbers, names, and text addressed to an AI. After validator v1 found an overview naming people
  absent from its cited lines, unsupported names became a doubt trigger (the verifier can't clear it), and overview
  sentences with names or numbers absent from their cited items' lines are dropped. This is deliberately strict and can
  over-drop: on ES2004a a validator run dropped 3 sentences, so **the overview can be empty**. The UI then shows the
  items without an overview. Capitalised titles not spoken in the cited lines can also raise a doubt. Duplicate items can survive when
  the transcript itself repeats (the looped synthetic transcript).
- **Speed is a risk for the base-M2 budget.** Notes for 120 minutes take about 8 minutes on the M2 Max. A base M2
  has about a quarter of the GPU, so notes alone could exceed the plan's 20-minute total for a 120-minute meeting.
  Levers: fewer items per chunk (96 were extracted and then capped), batched verification, Qwen3-1.7B (2.5× faster;
  quality untested). Tracked as item 18; measured in T12.
- Decisions handed down rather than agreed (for example a price set by management) become topics. The AMI reference
  calls some of them decisions.
