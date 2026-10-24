# Notes 0002: Faster notes: batched generation, compact output, notes yield to transcription (T18)

Date: 2026-10-22 · Task: T18 (docs/milestone-e-performance-plan.md) · Status: Accepted (user scope decisions
2026-10-22: notes output may change if the G5 notes checks pass; draft model allowed; Qwen3-1.7B measured only;
pause-and-resume priority). Amends notes/0001 (pipeline steps 2–4, `notes-v1` → `notes-v2`) and processing/0001
(scheduling of the notes stage).

## Context

T16 (docs/qualification/milestone-e-t16-breakdown.md) and T17 left notes for a 60-minute meeting at 206–252 s
(Release, M2 Max) against G2 ≤ 300 s: a thin margin, and about 8 minutes for 120 minutes. Notes were
generation-bound: one sequence at a time decodes at 51–62 tokens/s at a 5,400-token context, with the GPU mostly
idle. Notes also waited for, and blocked, transcription work of newer meetings.

## Measurements (M2 Max, Release, llama.cpp b11669 Metal, Qwen3-4B-Instruct-2507 Q4_K_M)

Tools: `amaranth-bench llm-probe`, `notes-trace` (logs every model call of one notes run), `spec-sim`, `draft-sim`,
`notes-gate` (Benchmarks/Harness). Traces of the 60-minute planted fixture are the input to the simulations.

| Lever | Result | Used |
|---|---|---|
| **Compact JSON output.** The grammar allowed pretty-printed JSON; the model used it | About 32% of generated tokens were indentation and newlines. `ws ::= " "?` removes them; same content | **Yes** |
| **Several sequences in one batch** (unified KV cache) | Decode throughput: 1 sequence 51–62 tok/s; at long context 4 sequences 97 tok/s; at short (verification) context 8 sequences 200 tok/s, 16 sequences 264 tok/s | **Yes**: up to 16 |
| Unified vs per-sequence KV | Per-sequence is 114 vs 97 tok/s at 4 long sequences, but needs a fixed context per sequence (16 × 8,192 tokens does not fit the memory budget); unified shares 24,576 cells and lets short verifications reuse a chunk's prompt | Unified |
| **KV prefix reuse** | Verifications share the system prompt; the longest common prefix is copied between sequences (`seq_cp`) instead of being recomputed | **Yes** |
| Flash attention | Off is much slower at long context | On (was already) |
| Quantised KV (q8_0) | Slower than f16 on Metal at these sizes | No |
| n_ubatch 2,048 (vs 512) | Faster prefill, but decode 40% slower | No (512) |
| Prompt-lookup speculation (no draft model) | About 2.1 tokens accepted per step on the real calls: below the cost of the larger verification batch | No |
| **Draft model** Qwen3-0.6B Q8_0 (HF `Qwen/Qwen3-0.6B-GGUF`, rev `23749fef`, Apache-2.0) | Token acceptance α 0.765 on extraction, 0.86–0.89 on verification. Speculation helps a single sequence, but with 16 sequences in flight the GPU is already busy; the draft's own prefill adds about 9 s per meeting. Net gain about zero | **No**: no pack change |
| Earlier item caps | Extraction stays at ≤ 16 items per chunk; with batched verification the remaining cost is the extraction chunks, not the item count | No change |
| Smaller model Qwen3-1.7B | See "Qwen3-1.7B" below | No (measure only, as agreed) |

Prefill is about 890 tok/s and is no longer the bottleneck.

## Decision

1. **Engine** (`LlamaRunner`). One context with a unified KV cache of 24,576 cells and up to 16 sequences, flash
   attention, f16 KV, n_batch 2,048, n_ubatch 512, greedy, grammar-constrained per sequence. `generateStream` runs
   continuous batching:
   - a request is admitted when its prompt plus maximum output fits the free cells; later small requests may fill in
     behind a large one;
   - each sequence starts from the longest cached prefix of any sequence (`seq_cp`), and idle caches are evicted when
     space is needed;
   - each step decodes one token for every running sequence plus a slice of pending prompt, so long prompts never
     stall the others;
   - results are delivered as each sequence finishes, and the caller may add follow-up requests.
   Single calls (`generate`) are a batch of one. `configHash` is `chatml-manual-v1:ctx8192:greedy:batch16x24576`, so
   old checkpoints are not reused. Per-call context is still 8,192 tokens.
2. **Prompts** (`NotesPrompts`, `notes-v2`). All grammars emit compact JSON. Prompt texts are unchanged.
3. **Pipeline** (`NotesPipeline`). Extraction, repair and verification form one stream:
   - all chunks are extracted together; an invalid extraction immediately queues its one repair (≤ 8 items);
   - the deterministic checks run per chunk as it finishes;
   - verification requests are released for chunks in meeting order, once a chunk and every earlier chunk are
     checked, so the 120-verification cap selects the same items as before (the first 120 in meeting order);
   - every result is checkpointed as soon as it finishes; resume skips finished calls;
   - assembly (limitations, verdicts, merge, caps) is unchanged and runs in chunk order, so the output does not depend
     on completion order (test `batchedCallsGiveTheSameNotesAndCheckpointAsTheyFinish`).
   Reduce and overview are unchanged.
4. **Priority** (`JobScheduler`). Notes are the lowest priority:
   - a queued notes job does not start while any non-notes job is queued, running or suspended (except a job the
     user paused);
   - a running notes job is cancelled when transcription-side work appears. It returns to the queue without using a
     retry attempt and resumes from its checkpoints. The job watchdog looks every 250 ms and the engine checks
     cancellation at every decode step, so the yield takes well under a second; the calls still in flight are
     redone on resume, finished ones are not (test `runningNotesYieldToNewTranscriptionWorkAndResume`).
5. **Idle-loop fix** (`JobScheduler`, pre-existing since T08). The idle wait used `AsyncStream` with a timeout task;
   cancelling the waiting consumer finishes the stream, so every later wait returned at once and the app sat at
   100% CPU while idle. Replaced by a single-waiter `WakeSignal` (test `idleSchedulerWaitsInsteadOfSpinning`).

## Results (perf-suite, Release, against the frozen v0 baseline)

Run `Benchmarks/Results/2026-10-22-perf-t18b/` (AC power, full suite, `--compare baseline-v0`): **G5 PASS, 0
breaches.** All transcripts are byte-identical to v0 (notes do not touch them).

| Item (seconds after Stop) | v0 (R2c) | **T18 (t18b)** |
|---|---|---|
| timing-2src-60min, notes (cold / warm) | 251.8 / 248.3 | **149.4 / 143.9** |
| of which the notes stage itself (cold) | 146.2 | 98.5 |
| notes-planted-60min | 259.9 | **124.2** |
| notes-planted-120min | 535.5 | **266.4** |
| notes-inject-0…9 (10 min each) | 20.6–29.7 | 4.5–18.5 |
| corpus meetings, notes (22–72 min) | 15.6–195.8 | 12.8–95.4 |
| timing-2src-60min, transcript (cold) | 104.9 | 50.2 (T17) |

- **G2 met: 144–149 s for 60 minutes (target ≤ 300 s).** 120 minutes: 266 s for the notes stage alone.
- **Notes quality checks (G5), notes and timing suites:** evidence valid 336/336; planted 8/8; injection 10/10;
  uncertain 111/336 = 33.0% (v0 aggregate 38.6%). Per item, uncertain counts are equal or lower except
  notes-planted-60min (25 vs 23), three injection fixtures (2–3 vs 1) and one corpus meeting (6 vs 4).
- **Corpus (the user's recordings), flag-only per T16:** all 5 meetings are flagged for "notes item overlap" below 70%
  (0–40%). That check needs the same kind and ≥ 50% shared words, and the wording changed. Comparing *where* items
  cite instead (cited segment starts within 5 s): 82–100% of the places v0's items cited are still cited, and item
  counts per kind are similar (for example 36 vs 36 items, 8 vs 17 uncertain on the 72-minute meeting). Every item's
  evidence is valid. Human review of the notes (tracked item 6) still applies.
- Where the time goes now (notes-planted-60min, 124 s): 62 calls; prefill of 53.6k new prompt tokens (15.4k reused)
  60.5 s, generation of 7.5k tokens 63.0 s, overview 3.6 s. Both halves are close to what this model can do on this
  GPU; the next large gain is extracting during the meeting (T19).

**Priority check** (`--suites yield`, run `Benchmarks/Results/2026-10-22-perf-t18c-yield/`): a 14-minute AMI meeting
(IS1009a) arrives while notes for the 120-minute fixture are generating. Its transcript is ready in **8.5 s**, against
7.8 s for the same meeting alone in t18b; its first stage waited 0.4 s. The notes yielded, started again once, and
finished 264 s after the meeting arrived.

## Qwen3-1.7B (measured only; not shipped)

`amaranth-bench notes-gate` with Qwen3-1.7B Q4_K_M (non-thinking prefix), same engine settings, notes suite:

| | Qwen3-4B (shipped, t18b) | Qwen3-1.7B |
|---|---|---|
| Time, planted 60 / 120 min | 124 / 266 s | 59 / 122 s |
| Evidence valid | 100% | 149/149 |
| **Planted decisions found** | **8/8** | **3/8** (0/2 at 60 min) |
| **Injection resisted** | **10/10** | **8/10** |
| Uncertain | 33% | 8% (fewer items, and it misses rather than doubts) |

About 2× faster, but it fails two notes checks. Not shipped, and no model pack change.

## Memory

- The KV cache is 24,576 cells × f16 ≈ 3.4 GB on top of the 2.5 GB model. Peak worker footprint during notes:
  3.7–3.9 GiB (v0: 1.3–1.5 GiB). The notes model is still exclusive with ASR and diarization
  (processing/0002), so the overall peak is notes alone.
- This fits the 16 GB base-M2 budget (app + worker ≤ 6 GiB) but leaves less margin. Fallback: `Configuration`
  with a smaller `kvTokens` and `parallel` (for example 12,288 × 8) halves the KV at some speed cost;
  `.sequential` restores the v0 engine shape.

## Limits

- Base M2 / 16 GB: unverified (no hardware). It has about a quarter of the M2 Max GPU; batching helps there too,
  because single-sequence decode is memory-latency-bound, but the speed-up is not measured.
- Output changed (compact JSON and batch numerics), so notes are not byte-identical to v0; the G5 notes checks are
  the acceptance bar, not identity.
- Greedy decoding in a batch is not bit-identical to single-sequence decoding (different kernel shapes), so two runs
  with different batch composition can differ in rare tokens.

## 2026-10-23 — T23: no topics (`notes-v3`)

Design review 2026-10-23 (decisions/0005): "Topics we don't really need." The user chose to remove topics
entirely (not keep them as a hidden intermediate step), and kept that choice after seeing its effect on the overview.

**Changes**

- Extraction asks for decisions, actions and open questions only; the grammar has no `topic` kind and no `title`
  field. A stray `topic` from the model is dropped like any unknown kind. `SummaryContent.topics` stays in the frozen
  contract (old revisions decode and export it) but new revisions write `[]`.
- A decision the verifier calls a proposal (or `other`) is now dropped instead of being kept as a topic; a decision
  or action resting only on personal notes is dropped instead of becoming a topic. Personal notes can still support a
  question.
- Notes UI has no Topics section. Exports already skip empty sections, so new notes export without Topics and old
  revisions still export theirs (test in DataLifecycleTests).
- **Overview.** Topics were most of the overview's input; without them it came out empty on a real 36-min meeting
  (run t23). The overview now also reads up to 24 substantive transcript lines spread over the meeting and may cite
  them (`lines`). Safeguards, all added after measuring:
  - lines addressed to an AI (`EvidenceChecker.looksAddressedToAI`) are never sampled;
  - citations the model writes into the text ("supported by items [4] … lines [L533]") are stripped *before* the
    grounding check (they were being read as unsupported numbers);
  - the name check accepts the cited lines' speaker names (it rejected "Speaker 2 said …" before, also in v2);
  - every sentence that cites transcript lines is checked by the item verifier; "no" (or no verdict) drops it;
  - a sentence claiming an agreement or decision must cite a verified decision item (run t23c: "we agreed to double
    the price, even though we didn't" became an overview agreement). This is a word list (agreed, decided, chose,
    concluded, confirmed, committed, finalized, going with, signed off …), not a guarantee; the remaining defences are
    the data rule in the prompt, name/number grounding and the verifier ("partly" keeps a sentence).
  - Known limits (Milestone G validation): `looksAddressedToAI` patterns were shaped by the 10 injection fixtures, so a
    paraphrased injection can be sampled; name grounding skips sentence-initial words and number grounding is
    digit-only. Injection 10/10 is a regression guard, not proof of resistance.

**Version.** `NotesPrompts.version` and `PipelineVersions.notes` → `notes-v3`: the prompts changed, and checkpoint keys
and job config hashes must not mix versions (a test pins them equal). This does **not** make existing notes stale:
staleness is computed from the transcript revision, edit sequence and scratchpad only (`NotesRecords`), and the
scheduler only auto-enqueues notes for meetings that have none. Existing notes keep their stored topics until
regenerated: the Notes tab no longer shows them, but exports of those old revisions still include a Topics section.

**Measurements** (Release, M2 Max; `--suites corpus,notes`, 60-min corpus timing not run by user decision;
docs/qualification/milestone-g-t23-notes.md): G5 pass; evidence 108/108; planted 2/2 (the 120-min planted item is
not run, per the no-runs-over-60-min rule); injection 10/10; uncertain 25.0% (v2: 33.0%). Notes stage is faster and
the overview keeps at least as many sentences on real meetings; on the synthetic planted transcript it has 1 sentence
(v2: 4).
