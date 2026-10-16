# Milestone A: brief for the independent validator

You are validating **Milestone A ("Prove feasibility")** of Amaranth, a local macOS meeting recorder and transcriber.
The repo is `/Users/alex/sandbox/amaranth-v2`. The plan is `docs/development-plan.txt`, and the backlog with acceptance
criteria is `docs/implementation-tasks.json` (tasks T01–T04).

Milestone exit (plan §12): *"T01 contracts, T02 model harness, T03 capture spike, T04 model packaging. Exit with a working
recorder, reproducible benchmark artifacts, compatible model/runtime pins, and a written go/no-go decision."*

## Ground rules
- Be adversarial and independent. Don't accept a claim in a doc unless you can check it against code, tests, raw
  evidence files, or by running something. Report anything overstated, unsupported, or contradicted.
- Hardware context: there is only one machine, an M2 Max (96 GB) on macOS 26.5.2. Base-M2/16 GB and 8 GB hardware are
  **unavailable**. The plan requires such gates to be marked **unverified**, not passed. Check that the docs do this.
- **Don't** run the app's audio-capture self-tests (`capture-signals`, `capture-routes`, `capture-soak`, `capture-tone`) or
  rebuild the app in a way that triggers them. They raise macOS permission prompts that need a person. Validate capture
  from the code, the unit tests, and the raw evidence JSONL in `docs/qualification/evidence/2026-10-16/` instead.
- **Don't** modify source files. You may run builds and tests, and write scratch files under `/tmp`.
- You may run: `scripts/check.sh`; `swift test --scratch-path /tmp/amaranth-validate`; the worker self-tests (no
  permissions); `amaranth-bench corpus … --score-only` to recompute scores from cached raw results;
  `amaranth-models build-pack|verify`.
- User-confirmed scope changes are in `docs/decisions/0003-confirmed-scope.md`. Notably, live text was **promoted**
  (T14 is no longer optional).

## What to check (per acceptance criteria in implementation-tasks.json)
- **T01:** app and worker build with the pinned toolchain; contract round trips (source, overlap, unknown speakers,
  null owners, evidence); a worker crash is observable without killing the app; fixture UI distinguishes captured
  audio from failed processing; confirmed choices and assumptions are documented.
- **T02:** reproducible quality and timing for the candidates, including 60- and 120-minute runs; no selection rests on
  read speech or vendor numbers alone; word timestamps, final-window behaviour, cancellation and meeting-wide speaker
  consistency are validated, or honestly flagged as not yet validated; a go/no-go for 16 GB and a separate decision for
  8 GB; no main-branch or latest pins.
- **T03:** mic and system both captured and distinct; first frames ≤ 2 s and first commit ≤ 4 s; meeting-app trials
  (manual; check they're honestly marked pending/untested); no mute or rerouting; self playback excluded; 30 min loaded
  capture with no overruns, no unannounced discontinuities, and no blocking or allocating callback work (inspect
  `Capture/RealtimeC`).
- **T04:** explicit download and local import with hashes, sizes, revisions and notices; atomic activation; interrupted
  installs never activate partial files; corrupt models reported without a hidden network repair; record-only stays
  available; attribution and provenance per shipped asset; offline sample verification.

## Output
Write a verdict file at `/tmp/milestone-a-verdict.md` and also return it as your final message:
- an overall **PASS / PASS WITH CONDITIONS / FAIL**;
- per task: met criteria (with the evidence you checked), unmet or overstated criteria, and anything you could not verify;
- a short, prioritized list of required fixes before Milestone B, and a separate list of acceptable deferrals.
