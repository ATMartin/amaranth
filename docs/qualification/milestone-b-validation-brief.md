# Milestone B: brief for the independent validator

You are validating **Milestone B ("Durable processing core")** of Amaranth, a local macOS meeting recorder and
transcriber. The repo is `/Users/alex/sandbox/amaranth-v2`. The plan is `docs/development-plan.txt`, and the backlog with
acceptance criteria is `docs/implementation-tasks.json` (tasks **T05–T08**). Milestone A passed; its verdicts are in
`docs/qualification/milestone-a-verdict-v*.md`.

## Ground rules
- Be adversarial and independent. Don't accept a claim in a doc unless you can check it against code, tests, raw
  evidence files, or by running something. Report anything overstated, unsupported, or contradicted.
- Hardware context: there is only one machine, an M2 Max (96 GB) on macOS 26.5.2. Base-M2/16 GB and 8 GB gates must be
  marked **unverified**.
- The user has not yet supplied real-call recordings. Quality gates can only be measured on public data (AMI,
  LibriSpeech) and synthetic fixtures. Check that the docs say so and don't claim the plan §10 held-out gates are met.
- **Don't** run the app's audio-capture self-tests (`capture-signals`, `capture-routes`, `capture-soak`, `capture-tone`).
  They raise macOS permission prompts that need a person.
- **Don't** modify source files, docs, or `~/Library/Application Support/Amaranth/`. Write scratch files only under
  `/tmp`.
- You may run:
  - `scripts/check.sh` (about 3 min);
  - `swift test --scratch-path /tmp/amaranth-validate-b`, optionally with `--filter <name>`;
  - the synthetic self-tests, which need no permissions:
    `build/DerivedData/Build/Products/Debug/Amaranth.app/Contents/MacOS/Amaranth --self-test pipeline-e2e --repo $PWD`
    (also `kill-worker-while-recording` and `hung-worker-recycled`; each takes 1–3 minutes);
  - `.build/release/amaranth-bench production-eval ModelStore Benchmarks/Fixtures/public /tmp/<dir>`
    (copy `Benchmarks/Results/2026-10-16-t02-run1/inputs/control-*.wav` into `/tmp/<dir>/inputs/` first; about 2 min);
  - `.build/release/amaranth-bench asr-sweep ModelStore Benchmarks/Fixtures/public Benchmarks/Results/2026-10-16-t02-run1`
    (about 4 min; it writes into that results directory, which is acceptable);
  - `.build/release/amaranth-bench asr-probe ModelStore <16k wav> <start> <end>`.

## Documents to check
- `docs/decisions/storage/0001-storage-and-recovery.md` (T05)
- `docs/decisions/asr/0001-asr-pipeline.md` (T06), including two claimed engine defects:
  - FluidAudio chunk drops above 15 s;
  - a greedy TDT pass skipping a whole span depending on context. You can reproduce this one with `asr-probe` on
    `Benchmarks/Results/2026-10-16-t02-run1/sweep-inputs/libri-1089/systemOutput-16k.wav 63.74 74.75`.
- `docs/decisions/diarization/0001-diarization-and-attribution.md` (T07)
- `docs/decisions/processing/0001-orchestration.md` (T08)
- `docs/qualification/tracked-items.md`
- Raw evidence: `docs/qualification/evidence/2026-10-16/` (`swift-test-metrics.txt`, `production-eval-*.txt`,
  `asr-sweep.txt`, `selftest-*.jsonl`) and `Benchmarks/Results/2026-10-16-t02-run1/diar-memory.txt`.

## What to check (per acceptance criteria in implementation-tasks.json)
- **T05:**
  - force-kill recovery of every committed segment with ≤ 5 s tail loss (`Tests/Recovery`, `Tests/RecoveryChild`);
  - a healthy source continues while the other fails;
  - a two-hour run with no PCM accumulation and normalized drift < 100 ms;
  - low disk saves and deletes nothing;
  - the recovery paths (lost index, truncated file, staging salvage, torn journal);
  - gaps are never presented as silence.
- **T06:**
  - boundary fixtures (first and last words, dates, numbers, negations, no duplicates);
  - pause/resume and sample-rate changes keep timestamps;
  - unknown coverage is never omitted;
  - WER and runtime measured per subset, with honest labelling as public-only;
  - silence/music controls produce nothing;
  - cancel/restart gives the same transcript without re-running checkpointed windows;
  - whether the under-yield guard can invent text or hide losses.
- **T07:**
  - DER, coverage and attribution precision versus plan §10. DER is claimed **not met** on clean AMI and attribution
    is claimed met; check the computation in `Benchmarks/Harness/main.swift` `productionEval`;
  - uncertainty is kept and no names are invented;
  - echo handling never erases real interruptions;
  - edits survive reprocessing or are flagged;
  - 2–4 h memory is bounded.
- **T08:**
  - kill/hang of the worker during recording;
  - a second meeting immediately after the first, with a cold model and a failed prior stage;
  - relaunch requeue without duplicates or lost edits;
  - cancellation, deletion and stale-revision tests;
  - one heavy stage at a time;
  - suspension during recording and under thermal/memory pressure;
  - no inference in the capture process.

Milestone B exit (plan §12): *"Reliable recorder: T05 durable storage, T06 ASR, T07 diarization, T08 job orchestration.
Recording/recovery is independently usable. Force-kill the inference worker while capturing and prove the audio
survives. A failed AI job is not a failed recording."* Judge whether known gaps (DER on clean AMI, real-call corpus, language ID,
blockwise over-splitting, offline check of the worker process) are acceptable deferrals with owners, or whether any
must be fixed before Milestone C (notes and UI).

## Output
Write a verdict file at `/tmp/milestone-b-verdict.md` and also return it as your final message:
- an overall **PASS / PASS WITH CONDITIONS / FAIL**;
- per task: met criteria (with the evidence you checked), unmet or overstated criteria, and anything you could not verify;
- a short, prioritized list of required fixes before Milestone C, and a separate list of acceptable deferrals.
