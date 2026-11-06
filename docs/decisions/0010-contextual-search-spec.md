# 0010 — Contextual search over meeting history

Date: 2026-11-06 · Status: **Defined with user-confirmed product requirements** (2026-11-06). Implementation has not started; model/runtime choices and engineering budgets are verified in T109/T110.
Milestone **V**, tasks **T109–T116**, in `docs/implementation-tasks.json`.

## Outcome

Ask should understand a question, find the relevant conversation even when it uses different words, and answer from
current transcript evidence. The user's example is: “What did Andrew propose as a new career goal last week?”
Finding lines containing “career goal” or “last week” is insufficient. A successful result could find Andrew saying
“I'd like to move into management,” establish that it was a proposal in the requested week, and cite that moment.
That quotation is an illustrative fixture, not a claim about a real meeting.

This is a planning change. V is the next requested milestone after completed S. Preserve the existing relative order
after it: T21 → T (external MCP) → U (vault mirror) → feedback → F. T/U are not prerequisites for in-app contextual search.

The first pass prioritizes general topic, decision and action questions across mostly unnamed transcripts. Named
speaker support is useful when evidence exists, but completion does not depend on the separate naming rollout.

### User examples and required behavior

| Question | Required interpretation and evidence |
|---|---|
| “What was said in the last week regarding who can staff the Trane project?” | Retrieve staffing availability/capacity/assignments for Trane across the rolling past seven days, including indirect wording and multiple calls. Names mentioned in speech can answer who is available even when the speaker labels are anonymous. Distinguish tentative suggestions, actual availability and confirmed assignments; cite each supported claim. |
| “Did we make a final decision about strategic planning for 2027 yet?” | Search eligible history through the request time for the planning topic; 2027 describes the planning subject, not a meeting-year filter. Distinguish discussion/proposals from an explicit final decision, and examine later reversals or reopened decisions. If no decision is supported, say none was found in searched evidence; do not infer that no decision exists from a few ranked passages. |
| “What follow-up actions did I promise during my calls today?” | Resolve today in the request timezone; find explicit self-commitments rather than suggestions or assignments to others, preserve deadlines/conditions and cite each action. Resolve “I” only from a trustworthy current mapping to the user or explicit evidence. If identity is unresolved, ask which speaker is the user or offer clearly labeled commitments by anonymous speaker; never silently label everyone’s promises as the user’s. |

Use variants of these scenarios in the development and held-out evaluation, separated by meeting/scenario to avoid
leakage. Include successful general answers from entirely unnamed transcripts and safe limits on unsupported self-attribution.

## What exists and why it fails

Verified in the repository on 2026-11-06:

- `Storage/Search/Retriever.swift` selects passages with stemmed, OR-ed FTS5 terms, then builds nearby-line windows.
- `App/Library/AnswerModel.swift` retrieves before calling the local Qwen answer worker. With no lexical passages it
  immediately refuses, so a capable answer model never gets an opportunity to find semantically related evidence.
- `Notes/Answer/Answerer.swift` already generates cited answers, with a 2,200-token prompt budget. Its lexical
  checker and fixed prompt trimming also need review for paraphrased answers and multi-part questions.
- The result list in `App/Library/AskAnythingView.swift` uses separate keyword hits, so improving only the answer's
  retriever would leave the visible sources misleadingly lexical.
- S supplies current-content snapshots, source URLs, date/folder/participant filters and bounded reads in
  `MeetingAccess/`. External search is explicitly model-free today; preserve that contract by default.
- [T98's report](../qualification/milestone-s/t98-retrieval-report.md) measured lexical/name Recall@10 at 33/33 and
  paraphrase Recall@10 at 2/8. These are development baselines, not a held-out acceptance set for V.

## Recommended architecture

Use **local hybrid retrieval plus a bounded local LLM query plan**, then grounded answer generation. Embeddings
are numerical representations used to retrieve related wording; they are a derived search index, not model training.
The embedding encoder and the existing answer LLM have separate jobs. Do not assume the chat model's hidden states
are a suitable retrieval embedding space.

1. Freeze the user question, selected meeting/folder/all scope, request time and local timezone, and bounded recent
   conversation context. Earlier answers can resolve a follow-up but never become evidence.
2. Ask the existing local instruction model for schema-constrained search intent: semantic queries, literal terms,
   referenced people and their roles, date expression, and a small set of subquestions. Validate it before execution.
   The model cannot emit executable SQL, arbitrary tools, file paths or scope changes.
3. Resolve dates and known names deterministically against the permitted current metadata. Intersect every branch
   with explicit UI scope. Surface ambiguity instead of inventing a person or silently dropping a constraint.
4. Search both FTS5 and a local embedding index over the same permitted current transcript chunks. Fuse ranks
   (initial recommendation: reciprocal rank fusion); do not add incomparable raw cosine and BM25 scores.
5. Expand adjacent current transcript context and rerank a bounded candidate set for the actual question. Preserve
   enough before/after context for negation, pronouns, proposals versus decisions, and later corrections. A dedicated
   reranker model is an experiment only if measured gains justify its memory/download cost.
6. Assemble an evidence budget per subquestion/meeting and answer with source citations. Permit at most one bounded
   additional retrieval round for a missing piece. A small top-k is not an exhaustive history scan.

This is a fixed retrieval workflow, not an open-ended agent. Proposed starting limits: three subquestions, three
semantic query variants total, 60 fused candidate chunks, 12 final passages, and one extra retrieval round. T109/T110
must freeze executable token/input/time limits and measured budgets before implementation depends on them. Changing
the 12-passage or 2,200-token budget requires explicit benchmark evidence; token fitting must preserve required
evidence rather than repeatedly dropping the last-ranked passage without checking coverage.

### Model and vector storage choice

Evaluate a small dedicated local encoder first, with **Qwen3-Embedding-0.6B** as the initial candidate, using the
bundled llama.cpp runtime if compatible. Its official model card documents retrieval instructions, last-token
pooling and normalization; implement the selected model's actual recipe rather than copying generic mean pooling.
T110 verifies compatibility with the app's pinned llama.cpp b11669 before choosing an artifact. Pin upstream revision,
conversion, quantization, vector dimensions, preprocessing, query instruction, pooling, normalization, license and
file hashes. If compatibility or quality fails, compare a smaller supported encoder on the same development set.

Store chunk records, embedding vectors and producer identities in app-owned SQLite initially. Benchmark exact cosine
scoring with scope-first filtering and bounded memory at 200 meetings / approximately 200,000 transcript lines.
Do not preselect an external vector service or a vector extension. If exact scanning misses the measured latency or
memory gate, evaluate an embedded local approximate index; record recall versus exact results, scope enforcement,
deletion and packaging costs before adopting it. A candidate cap must not silently omit later meetings. Chunk count,
not just meeting count, must appear in the report.

Primary sources checked 2026-11-06 (capability documentation, not app performance evidence):

- [Qwen3-Embedding-0.6B model card](https://huggingface.co/Qwen/Qwen3-Embedding-0.6B).
- [llama.cpp embedding example](https://github.com/ggml-org/llama.cpp/blob/master/examples/embedding/README.md).

## Indexing and data lifecycle

The current displayed transcript remains authoritative. Indexing never requires retranscription or regenerating
notes. Reuse S's safe current-content projection and provenance rules; do not embed hidden original revisions,
trimmed/deleted words, audio, work files or raw calendar payloads.

- Split by transcript turn/paragraph boundaries, initially targeting 200–400 encoder tokens with bounded overlap.
  Split oversized turns without dropping their middle/end. Record exact source spans and word ranges; citations
  must refer to original current text, not synthesized chunk summaries. Preserve shown speaker metadata and order.
- Carry meeting ID, source type, transcript revision, relevant edit generation/content hash, segment/word ranges,
  chunking version and embedding producer identity. Keep metadata filterable independently of vector text. Use a
  scoped generation/version token to invalidate a search if metadata or folder membership changes.
- Start embeddings after a committed final transcript becomes available, without waiting for notes. Do not index
  provisional live text in V. Index existing meetings through a resumable background backfill.
- Text correction, retranscription, trim, delete/restore line, speaker rename/reassignment and meeting deletion
  invalidate affected records immediately in the content-changing transaction. Metadata/folder changes update
  filtering and generation; they need not re-embed unchanged text unless that metadata is part of encoder input.
  Idempotent content hashes allow unchanged chunks to be reused.
- A worker computes vectors from immutable input; only the app's controlled writer publishes them. Compare source
  identity and embedding producer at commit. An old job must not restore deleted text or replace newer edits.
- Persist checkpoints and readiness per meeting/model generation. Publish validated chunks atomically at a defined
  generation boundary; mix neither incompatible encoders nor old/new source generations in one answer.
- Deleting a meeting removes chunks, vectors, queued work and app-controlled cached passages. Delete Audio Only
  keeps transcript retrieval. Removing an embedding model disables semantic search, preserving ordinary data and
  keyword lookup; model replacement schedules a versioned rebuild. Do not claim secure erasure of OS/backups/WAL.
- Support pause, retry and rebuild, low disk, worker crash/relaunch, missing/corrupt model and interrupted migration.
  Migration must not hold the writer while generating embeddings. Show partial coverage accurately during backfill.

Transcript is the primary evidence for “what did X say/propose?” Existing current generated/user notes may supplement
discovery, with authorship/staleness labels and current transcript validation. V need not embed notes to ship. A user
note or an attendee record cannot establish that someone spoke, and stale notes cannot reintroduce trimmed transcript
text as a spoken quotation. Current displayed notes may still contain removed discussion under R/S's existing rules;
do not imply transcript trimming redacts the notes too.

## Person, date and conversational meaning

- Distinguish **speaker**, **person discussed**, and **meeting attendee**. “Andrew proposed” needs attributed speech
  or explicit supporting discussion; filtering to meetings attended by Andrew is insufficient. Never infer voice
  identity across meetings. Match current user-assigned labels and explicit transcript references. Ambiguous names
  or unknown attribution prompt a clarification or qualified answer, not a guessed speaker mapping.
- Unknown speaker labels do not prevent topic/decision/staffing answers whose content is explicit. For “I/my,” use
  only a reliable existing user-to-speaker mapping or explicit supporting identity evidence. Microphone audio alone
  is not proof of user identity when a microphone may be shared. Do not require a new cross-meeting voice identity
  feature or block general search on the separate speaker-naming rollout.
- Proposed date rule: “last week” is the preceding calendar week, Monday 00:00 through this Monday 00:00, in the
  request's local timezone; “in/over the last week” and “past seven days” are rolling intervals. Show the resolved
  date range in the UI so the interpretation can be corrected. “Today” is local midnight through the request time. On Friday
  2026-11-06 in America/New_York, “last week” means October 26–November 1 inclusive. Compute calendar boundaries
  across DST, then use inclusive-start/exclusive-end UTC filters and meeting start `clock.utcOrigin ?? createdAt`.
- A meeting “last week” and a goal “for next quarter” are different constraints. Resolve spoken relative dates from
  their meeting context; do not apply the date parser to every date phrase as a meeting-date filter.
- Follow-ups (“Did that change this week?”) inherit the subject, with the new time constraint replacing the old one
  as appropriate. Do not concatenate questions with conflicting dates. Scope changes end the current session.
- Comparisons should preserve each meeting's dated evidence, uncertainty, disagreement and corrections. “Every,”
  “never,” exact counts and exhaustive timelines need bounded enumeration of all eligible sources with coverage
  tracking; if that cannot complete, explicitly give a partial result and limitation. Ranked hits cannot prove absence.

## App integration and resource policy

User-confirmed experience: one Ask field produces a direct answer with clickable transcript citations, then relevant
contextual passages. Keep fast literal lookup accessible and clearly labeled. Do not display the old independent
keyword list as though it were the evidence used for the contextual answer.

**Required loading graphic (T115, validated in T116):** give immediate feedback within 250 ms of submission with a
small, friendly animated ring/seed motif that fits the existing Inner Circle / Forest identity
([UI 0004](ui/0004-inner-circle-identity.md)). Use existing rose/sage/cream tokens and a gentle orbit/pulse, with short
stage copy such as “Looking through your conversations…” and “Putting the answer together…”. It must remain visible
through model loading, planning, retrieval and pre-answer generation, transitioning naturally to streamed text.
Avoid an empty pane, fake completion percentages or an endlessly animated timeout. Use a static motif with status
text for Reduce Motion, an accessible progress label for VoiceOver, and keep Cancel/keyboard controls available.
Waiting for recording/indexing is labeled honestly; stop the active animation on completion, error, cancel or deadline.

**User-confirmed maximum: 15 seconds for the first pass.** One foreground attempt has a 15-second end-to-end wall-clock
deadline from submission, including queueing, cold model load, planning, retrieval, optional reranking/extra retrieval,
generation and checking. Do not reset the deadline for a subquery, retry, new stage or first streamed token. Schedule
work to leave cleanup/UI-delivery margin; by the deadline show a completed checked answer, a clearly labeled supported
partial answer, or an honest timeout/clarification/unavailable state with Retry. Never present unchecked streamed text
as the final answer. If recording prevents inference, promptly show that reason instead of spinning indefinitely;
a later explicit retry is a new attempt. Initial model installation and library backfill are separate visible setup
operations, not hidden work inside a query. A timeout counts as an answerability/latency miss, not a passing answer.

Show plain-language states: preparing search, searching, reading conversations, answering, waiting for recording,
indexing coverage, missing model/retry, clarification, insufficient evidence, and partial coverage. Avoid exposing
vector scores or prompt details as user decisions. No matching evidence, a failed search, and unfinished indexing
must have distinct messages; unavailable retrieval is not proof that nothing was discussed.

All indexing/planning/reranking/answer inference stays local and shares the worker's resource arbitration. Recording
and transcription retain priority. Background indexing yields first; foreground Ask must not sit behind the entire
backfill or notes batch. New question, scope change, Escape, pane close and Record cancel obsolete work through every
stage. Recheck source/scope generations before prompt construction and result delivery; suppress a stale answer if
its evidence was edited/deleted mid-flight. Existing visible answers/history must be cleared or marked stale when
their sources change. Bound queued work and memory; do not keep an entire library's decoded transcripts on the main actor.

Reuse storage/citation primitives without adding inference dependencies to `Storage` or the existing model-free
`MeetingAccess` list/search/get path. A separate app-side contextual orchestrator can call the same scoped primitives.
Future MCP can opt into semantic retrieval through an explicit contract; V does not implement T or change its grants.

## Proposed acceptance gates (freeze in T109)

All numbers below are targets, not measurements. Record exact hardware/OS/model pins and raw counts.

1. **Evaluation design:** retain the N/S sets as regression/development inputs. Create a distinct held-out set of at
   least 60 questions, separated by meeting/scenario from tuning: 40 answerable (at least 20 paraphrases, 10 combined
   person/date questions, 10 multi-part/cross-meeting/follow-ups; categories may overlap), 10 unanswerable, and 10
   ambiguous/adversarial. Annotate all required evidence spans and expected meaning. Include the user's example,
   all three additional user scenarios above, indirect references, negation, changed plans, wrong-week/wrong-speaker distractors, unknown speakers, names mentioned
   by others, DST/week boundaries, notes-only content and incomplete indexing. Use synthetic/consented data, never
   silently read the user's live library. Freeze before tuning; report any later adjustment.
2. **Retrieval:** at least 90% question-level Recall@10 on held-out paraphrases (all required spans, not just one
   convenient hit), at least 95% on person/date cases; lexical/name Recall@10 at least 95% and no material regression
   versus the same frozen baseline. Report category counts and pre/post prompt-fitting recall.
3. **Answers:** at least 90% fully correct on answerable questions by human rubric, at least 95% of factual claims
   supported, 100% valid current citations, zero wrong-person or wrong-period attributions on the controlled suite.
   All unanswerable cases abstain; ambiguous cases clarify/qualify without inventing facts; all planted instruction
   attacks fail to redirect the workflow. Score text meaning and completeness separately from citation validity.
4. **Lifecycle:** no stale/out-of-scope/deleted transcript text returned after edits/deletion, including jobs and answers
   already in flight; backfill resumes after restart; partial coverage is visible; upgrade/rebuild preserves source
   content; scope-first retrieval and citation navigation remain correct.
5. **Performance:** reference M2 Max profile; at least 200 meetings / 200,000 source lines, report actual chunk/vector
   count, database growth, backfill duration, throughput, app+worker physical footprint, queue delay and cancellation.
   User requirement: every foreground attempt reaches a completed checked answer or explicit terminal state within
   15 s, warm or cold, including queueing; timeouts/partial answers count against full-answer correctness. Engineering
   targets: warm contextual retrieval p95 <= 2 s excluding LLM planning; keyword lookup p95 <= 1 s, cancellation
   acknowledged <= 1 s; loading feedback <= 250 ms. Measure at least 100 varied
   warm queries plus 20 process-cold runs and separate model load/planning/retrieval/rerank/generation costs. Report
   encoder/answer residency and model switching. Larger libraries and 8/16 GB remain unverified unless actually tested.
6. **Delivery:** packaged offline record → process → index → ask → edit → ask → delete → ask flow; appropriate
   `scripts/check.sh` checks; capture under indexing/query load has no unreported loss; independent milestone validator
   per existing backlog convention. Verify the on-theme loading graphic and stage messages in light/dark mode,
   Reduce Motion and VoiceOver, including cold load, slow/timeout, waiting and cancellation. No automatic
   publish/install is added to this planning request.

If a target fails, keep the failure visible, fix or revise the proposal with evidence. Keyword fallback may keep the
app usable but cannot be called completion of contextual search. Do not lower a quality gate merely to preserve N's
old <= 3-second first-text target.

## Task sequence

| Task | Deliverable | Depends on |
|---|---|---|
| T109 | Freeze question semantics, evaluation/rubric, bounded contracts and budgets | T100 |
| T110 | Benchmark/pin local embedding model and prove packaged runtime path | T109 |
| T111 | Versioned current-transcript chunks/vector storage and migration | T109, T110 |
| T112 | Resumable backfill, incremental indexing and worker arbitration | T111 |
| T113 | Local LLM query plans, deterministic dates/people and follow-ups | T109, T110 |
| T114 | Scope-first hybrid retrieval, context expansion and bounded reranking | T112, T113 |
| T115 | Grounded answers, contextual sources, on-theme loading graphic and 15-second deadline | T114 |
| T116 | Held-out, lifecycle, scale, offline packaged and independent qualification | T115 |

## Confirmed product decisions (2026-11-06)

1. Direct answers with clickable citations are the primary output; contextual passages remain supporting evidence.
2. The first pass may take at most 15 seconds and must show a friendly on-theme loading graphic. T115 implements
   this, T110 measures model startup within the shared budget, and T116 validates warm/cold deadlines and loading UX.
3. Transcripts rarely have speaker names today. Prioritize general staffing, final-decision and follow-up-action
   questions using the examples above; do not depend on the separate naming rollout. Unsupported “I”/named-speaker
   attribution must be qualified or clarified while general semantic search remains useful.

No further product clarification is needed to define V. The date rule, automatic local backfill and extra small
embedding-model download are engineering recommendations delegated by the user; ordinary model installation must
still use the app's explicit verified download flow. All performance and quality gates await implementation evidence.

## Amendment (2026-11-06, after T116): search model required

User decision: contextual search is a core feature, not an optional upgrade, and there is **no keyword-only Ask**.
- Ask runs only when the model pack is installed with its search model. Otherwise the Ask pane is dimmed and inert,
  with what is missing and a link to Settings → Models (the only home of model setup, T77) on top. Recording,
  transcripts and notes work without the search model.
- The sidebar's model footer warns "Search model not installed" like "No local model found"; Settings → Models lists
  every model of the pack with its job, size and installed state, and downloads only what is missing.
- An attempt whose question the search model couldn't embed fails with Retry instead of answering from keyword matches.
  With the encoder installed but no producer reported yet, Ask searches the vectors of the encoder that embedded the
  question (`ContextualRetriever.learnsProducer`).
- Kept: the exact-word matches listed under an answer (labeled as such, not the answer's evidence) and the lexical
  list inside hybrid retrieval; meetings not yet indexed during backfill are matched by exact words only, and the answer
  says so.
