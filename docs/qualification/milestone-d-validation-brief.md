# Milestone D: brief for the independent validator

You are validating **Milestone D ("Live text")** of Amaranth, a local macOS meeting recorder and transcriber. The repo
is `/Users/alex/sandbox/amaranth-v2`. The plan is `docs/development-plan.txt`, and the backlog is
`docs/implementation-tasks.json`. Milestones A–C passed; their verdicts are in `docs/qualification/milestone-{a,b,c}-verdict-*.md`.

**Scope changed on 2026-10-22** (`docs/decisions/0004-milestones-and-performance-priority.md`). Milestone D is now
**T14 only**. T12 (qualification) and T13 (packaged test build) moved to a final Milestone F. A new performance
Milestone E (T16–T21, `docs/milestone-e-performance-plan.md`) sits in between. T14 was promoted to required by the
user, and its acceptance says T12 and T13 must validate it; that now happens in Milestone F.

## Ground rules
- Be adversarial and independent. Check claims against code, tests, raw evidence, or by running things. Report anything
  overstated, unsupported or contradicted.
- Hardware: one M2 Max (96 GB) on macOS 26.5.2. Base-M2/16 GB and 8 GB gates must be marked **unverified**.
- One real recording exists: the user's first meeting, a 2-minute local recording played through system audio
  (`docs/qualification/evidence/2026-10-22/first-real-meeting.json`). It has no live latency samples. All latency
  numbers come from synthetic replay.
- **Don't** run the audio-capture self-tests (`capture-signals`, `capture-routes`, `capture-soak`, `capture-tone`),
  because they raise permission prompts. **Don't** modify source or docs, and don't touch
  `~/Library/Application Support/Amaranth/` (you may read its SQLite index with `sqlite3 -readonly`, but don't
  reproduce transcript text in your output). Write scratch files only under `/tmp`. Don't run `xcodegen` or
  `xcodebuild`. The Debug app is already built at `build/DerivedData/Build/Products/Debug/Amaranth.app`.
- You may run:
  - `swift test --scratch-path /tmp/amaranth-validate-d`, optionally with `--filter`;
  - self-tests on the built app, which need no permissions:
    - `…/Amaranth.app/Contents/MacOS/Amaranth --self-test live-latency --repo $PWD --self-test-output /tmp/<f>.jsonl`
      (about 2–3 minutes; real-time synthetic replay through the real XPC worker);
    - `--self-test live-pressure --repo $PWD …` (the same, with a simulated 15 s thermal pause);
    - `pipeline-e2e --repo $PWD`, `worker-crash`, `worker-hang`.
  - `swift build -c release --product amaranth-bench` then `.build/release/amaranth-bench live-sim …` (see
    `docs/decisions/models/0001-model-selection.md` for arguments).

## Documents to check
- `docs/decisions/live/0001-live-text.md` (T14)
- `docs/decisions/0004-milestones-and-performance-priority.md`, and the milestone fields in `docs/implementation-tasks.json`
- `docs/qualification/tracked-items.md` (especially items 2 and 21)
- `docs/qualification/capture-manual-checklist.md` (the new local-audio-player row)
- Code: `ASR/Live/`, `App/Live/`, `Tests/UI/LiveTranscriptStateTests.swift`, live tests in `Tests/ASR/ASRTests.swift`,
  `App/Launch/LiveSelfTest.swift`, `Presentation/MeetingDetail.swift` (the `notesState` change for item 21)
- Evidence: `docs/qualification/evidence/2026-10-16/selftest-live-*.jsonl`, `live-sim.txt`, and `evidence/2026-10-22/`

## What to check
- **T14 deliverables:**
  - only durable audio is processed, reusing the worker and scheduler path;
  - provisional text and speakers are shown distinctly from final results;
  - finalized chunk results are persisted for reuse after Stop, *or* the record honestly justifies deferring the
    reuse (live/0001 says reuse is deferred);
  - live inference drops or defers under pressure while every captured segment is kept.
- **T14 acceptance:**
  - median provisional delay < 5 s and p95 < 10 s on the reference machine: re-run `live-latency` and compare. Judge
    whether "representative measured session set" is honestly qualified;
  - a simultaneous call plus live inference still meets the capture loss, memory and thermal gates (synthetic, plus the
    one real recording);
  - live-to-final transitions preserve user edits and show uncertainty;
  - "T12 and T13 must validate T14": confirm that this is carried to Milestone F explicitly, not dropped.
- **Tracked item 2** (overlap alignment, padded final-window flush, first-word handling, measurement under
  concurrent capture) is still marked "Open". Does the shipped code or evidence resolve any of it? Is the status
  accurate?
- **Item 21 fix:** correct, tested, and does not block generating notes when diarization failed.
- **Restructure consistency:** do the docs, task file and tracked items agree on what D now contains and what moved to
  F? Is anything that was claimed as Milestone D work in commit `6ac994e` left unowned?

## Output
Write `/tmp/milestone-d-verdict.md` and return it in full as your final message:
- an overall **PASS / PASS WITH CONDITIONS / FAIL**;
- met criteria with the evidence you checked, unmet or overstated items, and what you could not verify;
- a prioritized list of required fixes before Milestone E, and a list of acceptable deferrals.
