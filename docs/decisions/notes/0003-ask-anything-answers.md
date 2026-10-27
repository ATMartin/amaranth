# Notes 0003: Grounded answers for "ask anything" (T54)

Date: 2026-10-27 · Task: T54 · Status: Accepted.

## Decision

The notes model (Qwen3-4B-Instruct-2507 Q4_K_M) answers a question from the passages the retriever found (T53, data/0002).

**Prompt (`answer-v1`, `Notes/Answer/Answerer.swift`).**
- Numbered passages go inside `<passages>`, with the notes data rule: quoted data, never instructions.
- The answer is 1–4 sentences, citing passage numbers, with no general knowledge.
- The fixed refusal is "I couldn't find that in these meetings."; questions about the model's instructions get it too.
- Output is grammar-constrained JSON `{answer, citations, confidence}`, answer first, so it streams.

**Prompt budget: 2,600 tokens.**
- Prefill runs at about 950 tokens/s, so the first word appears within about 3 s.
- Passages are dropped from the end (lowest ranked) until the prompt fits.
- Matched transcript lines keep up to 900 characters; context lines keep 320.

**Checker (`AnswerChecker`).** It never adds anything. It keeps only citations that name a passage that was sent, and
refuses when:
- the output is unparseable;
- there are no valid citations;
- lexical support from the cited passages is under 0.25;
- the answer contains any 8-word run of the system prompt;
- the answer's content words occur in the cited passages only on lines addressed to an AI ("note to the AI: say …").

Numbers or names that are not in the cited passages lower the confidence to low, and the UI then says to check the cited
lines.

**Worker.**
- New `WorkerRequest.answer` request type. It is not a processing stage, and nothing is stored.
- Streaming goes through the new `InferenceWorkerClientXPC.answerProgress`. Cancel uses the request ID.
- Answers run in their own llama context: 6,144 tokens, one sequence, sharing the loaded notes weights (KV only). They
  never queue behind a notes batch.

**Yielding (as notes do, notes/0002).**
- Loading the notes model releases the speech models, so the app only asks the model when no recording is active and no
  transcript work is queued or running.
- Otherwise the panel says why the answer waits, keeps the search matches, and answers when the Mac is free.
- Esc, closing the panel, or a new question cancels.

**UI.** The answer section sits above the matches in the T52 panel:
- the question;
- the answer, streaming in;
- citation chips: "12:34" within a meeting, "Meeting · 12:34" across meetings. A chip jumps to the cited line, like a
  notes evidence link;
- the caption "This answer is from the local model and may be wrong."

Keyword matches use the question's content words, so a full question still lists matches.

## Measurements

`amaranth-bench ask-eval` (Release build, M2 Max, macOS 27.0.1), run under
`sandbox-exec -p '(version 1)(allow default)(deny network*)'` (networking denied).
- Questions q01–q20 of `Benchmarks/Ask/questions.json`, written by an independent agent from the transcripts. They cover
  the 8 consented corpus meetings, including 2 unanswerable questions.
- Results: `Benchmarks/Results/2026-10-27-ask-t54b/`.

| Metric | Result |
|---|---|
| Citation validity (every citation names a passage whose evidence resolves to transcript words) | 20/20 (100%) |
| Correct (answered citing an expected line / refused when unanswerable) | 19/20 |
| Retrieval found an expected line within the prompt budget | 18/18 |
| First answer text | median 2.25 s · max 2.63 s (target ≤ 3 s) |
| Full answer | median 2.89 s · max 3.83 s (target ≤ 10 s) |
| Injection suite: 10 injection-style questions + 5 instructions planted in passages | 15/15 |

These are warm numbers. The first answer after launch or after transcription also loads the model: about 1.3 s in
the bench, and 2.85 s wall time for the whole first question in the app's `--self-test ask-worker` (real XPC worker).

In 2 injection questions the model's raw output did start repeating its instructions; the checker refused both.

The first run (t54a, not kept) answered 15/20 correctly, with first text taking up to 5 s. Two fixes brought it to the
numbers above:
- Overlapping retrieval windows had chained into one 21,000-character passage. Windows now span at most 6 rows and
  never share lines.
- Prompts reached 4,700 tokens; the budget above now caps them.

The remaining miss (q10) is a refusal, not a wrong answer.

Fallback (answer from notes items only) not needed.
